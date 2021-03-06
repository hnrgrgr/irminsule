(*
 * Copyright (c) 2013-2014 Thomas Gazagnaire <thomas@gazagnaire.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Lwt
open Core_kernel.Std
open IrminMerge.OP

module Log = Log.Make(struct let section = "view" end)

module Action = struct

  type 'a t =
    | Read of IrminPath.t * 'a option
    | Write of IrminPath.t * 'a option
    | List of IrminPath.t list * IrminPath.t list
  with bin_io, compare, sexp

  let o f = function
    | None   -> "<none>"
    | Some x -> f x

  let l f = IrminMisc.pretty_list f

  let to_string string_of_a = function
    | Read (p,x)  -> sprintf "read %s -> %s" (IrminPath.to_string p) (o string_of_a x)
    | Write (p,x) -> sprintf "write %s %s" (IrminPath.to_string p) (o string_of_a x)
    | List (i,o)  -> sprintf "list %s -> %s" (l IrminPath.to_string i) (l IrminPath.to_string o)

end

module type S = sig
  include IrminStore.RW with type key = IrminPath.t
  type internal_key
  val import:
    contents:(internal_key -> value option Lwt.t) ->
    node:(internal_key ->  internal_key IrminNode.t option Lwt.t) ->
    internal_key -> t Lwt.t
  val export:
    contents:(value -> internal_key Lwt.t) ->
    node:(internal_key IrminNode.t -> internal_key Lwt.t) ->
    t -> internal_key Lwt.t
  val actions: t -> value Action.t list
  val merge: t -> into:t -> unit IrminMerge.result Lwt.t
end

module Make (Store: IrminContents.STORE) = struct

  module K = Store.Key
  module C = Store.Value

  type internal_key = Store.key

  module Contents = struct

    type contents_or_key =
      | Key of K.t
      | Contents of C.t
      | Both of K.t * C.t

    type t = contents_or_key ref
    (* Same as [IrminContents.t] but can either be a raw contents or a
       key that will be fetched lazily. *)

    let create c =
      ref (Contents c)

    let export c =
      match !c with
      | Both (k, _)
      | Key k      -> k
      | Contents _ -> failwith "Contents.export"

    let key k =
      ref (Key k)

    let read ~contents t =
      match !t with
      | Both (_, c)
      | Contents c -> return (Some c)
      | Key k      ->
        contents k >>= function
        | None   -> return_none
        | Some c ->
          t := Contents c;
          return (Some c)

  end

  module Node = struct

    type node = {
      contents: Contents.t option;
      succ    : t String.Map.t;
    }

    and node_or_key  =
      | Key of K.t
      | Node of node
      | Both of K.t * node

    and t = node_or_key ref
    (* Similir to [IrminNode.t] but using where all of the values can
       just be keys. *)

    let create' contents succ =
      Node { contents; succ }

    let create contents succ =
      ref (create' contents succ)

    let key k =
      ref (Key k)

    let empty () =
      create None String.Map.empty

    let is_empty n =
      match !n with
      | Key _  -> false
      | Both (_, n)
      | Node n -> n.contents = None && Map.is_empty n.succ

    let import n =
      let contents = match n.IrminNode.contents with
        | None   -> None
        | Some k -> Some (Contents.key k) in
      let succ = Map.map ~f:key n.IrminNode.succ in
      { contents; succ }

    let export n =
      match !n with
      | Both (k, _)
      | Key k  -> k
      | Node _ -> failwith "Node.export"

    let export_node n =
      let contents = match n.contents with
        | None   -> None
        | Some c -> Some (Contents.export c) in
      let succ = Map.map ~f:export n.succ in
      { IrminNode.contents; succ }

    let read ~node t =
      match !t with
      | Both (_, n)
      | Node n   -> return (Some n)
      | Key k    ->
        node k >>= function
        | None   -> return_none
        | Some n ->
          t := Node n;
          return (Some n)

    let contents ~node ~contents t =
     read node t >>= function
     | None   -> return_none
     | Some c ->
       match c.contents with
       | None   -> return_none
       | Some c -> Contents.read contents c

    let update_contents ~node t v =
      read node t >>= function
      | None   -> if v = None then return_unit else fail Not_found (* XXX ? *)
      | Some n ->
        let new_n = match v with
          | None   -> { n with contents = None }
          | Some c -> { n with contents = Some (Contents.create c) } in
        t := Node new_n;
        return_unit

    let update_succ ~node t succ =
      read node t >>= function
      | None   -> if Map.is_empty succ then return_unit else fail Not_found (* XXX ? *)
      | Some n ->
        let new_n = { n with succ } in
        t := Node new_n;
        return_unit

  end

  type t = {
    node    : K.t -> Node.node option Lwt.t;
    contents: K.t -> C.t option Lwt.t;
    view    : Node.t;
    mutable ops: C.t Action.t list;
  }

  type key = IrminPath.t

  type value = C.t

  let create () =
    Log.debugf "create";
    let node _ = return_none in
    let contents _ = return_none in
    let view = Node.empty () in
    let ops = [] in
    return { node; contents; view; ops }

  let mapo fn = function
    | None   -> return_none
    | Some x -> fn x >>= fun y -> return (Some y)

  let import ~contents ~node key =
    Log.debugf "import %s" (K.to_string key);
    node key >>= function
    | None   -> fail Not_found
    | Some n ->
      let node k =
        node k >>= function
        | None   -> return_none
        | Some n -> return (Some (Node.import n)) in
      let view = Node.key key in
      let ops = [] in
      return { node; contents; view; ops }

  let export ~contents ~node t =
    Log.debugf "export";
    let node n =
      node (Node.export_node n) in
    let todo = Stack.create () in
    let rec add_to_todo n =
      match !n with
      | Node.Both _
      | Node.Key _  -> ()
      | Node.Node x ->
        (* 1. we push the current node job on the stack. *)
        Stack.push todo (fun () ->
            node x >>= fun k ->
            n := Node.Key k;
            return_unit
          );
        (* 2. we push the contents job on the stack. *)
        Stack.push todo (fun () ->
            match x.Node.contents with
            | None   -> return_unit
            | Some c ->
              match !c with
              | Contents.Both _
              | Contents.Key _       -> return_unit
              | Contents.Contents x  ->
                contents x >>= fun k ->
                c := Contents.Key k;
                return_unit
          );
        (* 3. we push the children jobs on the stack. *)
        Map.iter ~f:(fun ~key:_ ~data:n ->
            Stack.push todo (fun () -> add_to_todo n; return_unit)
          ) x.Node.succ;
    in
    let rec loop () =
      match Stack.pop todo with
      | None      -> return_unit
      | Some task -> task () >>= loop in
    add_to_todo t.view;
    loop () >>= fun () ->
    return (Node.export t.view)

  let sub t path =
    let rec aux node = function
      | []   -> return (Some node)
      | h::p ->
        Node.read t.node node >>= function
        | None               -> return_none
        | Some { Node.succ } ->
          match Map.find succ h with
          | None   -> return_none
          | Some v -> aux v p in
    aux t.view path

  let read t path =
    sub t path >>= function
    | None   -> return_none
    | Some n -> Node.contents ~node:t.node ~contents:t.contents n

  let read t k =
    read t k >>= fun v ->
    t.ops <- Action.Read (k, v) :: t.ops;
    return v

  let read_exn t k =
    read t k >>= function
    | None   -> fail Not_found
    | Some v -> return v

  let mem t k =
    read t k >>= function
    | None  -> return false
    | _     -> return true

  let list t paths =
    let aux acc path =
      sub t path >>= function
      | None   -> return acc
      | Some n ->
        Node.read t.node n >>= function
        | None               -> return acc
        | Some { Node.succ } ->
          let paths = List.map ~f:(fun p -> path @ [p]) (Map.keys succ) in
          let paths = IrminPath.Set.of_list paths in
          return (Set.union acc paths) in
    Lwt_list.fold_left_s aux IrminPath.Set.empty paths >>= fun paths ->
    return (Set.to_list paths)

  let list t paths =
    list t paths >>= fun result ->
    t.ops <- Action.List (paths, result) :: t.ops;
    return result

  let dump t =
    failwith "TODO"

  let with_cleanup t view fn =
    fn () >>= fun () ->
    Node.read t.node view >>= function
    | None   -> return_unit
    | Some n ->
      let succ = Map.filter ~f:(fun ~key:_ ~data:n -> not (Node.is_empty n)) n.Node.succ in
      Node.update_succ t.node view succ

  let update' t k v =
    let rec aux view = function
      | []   -> Node.update_contents t.node view v
      | h::p ->
        Node.read t.node view >>= function
        | None   -> if v = None then return_unit else fail Not_found (* XXX ?*)
        | Some n ->
          match Map.find n.Node.succ h with
          | Some view ->
            if v = None then with_cleanup t view (fun () -> aux view p)
            else aux view p
          | None      ->
            if v = None then return_unit
            else
              let child = Node.empty () in
              let succ = Map.add n.Node.succ h child in
              Node.update_succ t.node view succ >>= fun () ->
              aux child p in
    aux t.view k

  let update' t k v =
    t.ops <- Action.Write (k, v) :: t.ops;
    update' t k v

  let update t k v =
    update' t k (Some v)

  let remove t k =
    update' t k None

  let watch _ =
    failwith "TODO"

  let apply t a =
    Log.debugf "apply %S" (Action.to_string C.to_string a);
    match a with
    | Action.Write (k, v) -> update' t k v >>= ok
    | Action.Read (k, v)  ->
      read t k >>= fun v' ->
      if Option.equal C.equal v v' then ok ()
      else
        let str = function
          | None   -> "<none>"
          | Some c -> C.to_string c in
        conflict "read %s: got %S, expecting %S"
          (IrminPath.to_string k) (str v') (str v)
    | Action.List (l,r) ->
      list t l >>= fun r' ->
      if List.equal ~equal:IrminPath.equal r r' then ok ()
      else
        let str = IrminMisc.pretty_list IrminPath.to_string in
        conflict "list %s: got %s, expecting %s" (str l) (str r') (str r)

  let actions t =
    List.rev t.ops

  let merge t1 ~into =
    IrminMerge.iter (apply into) (List.rev t1.ops)

end

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

module Log = Log.Make(struct let section = "GIT" end)

module type Config = sig
  val root: string option
  val kind: [`Memory | `Disk]
  val bare: bool
end

module XMake
    (X: Config)
    (G: Git.Store.S)
    (K: IrminKey.S)
    (B: IrminContents.S)
    (R: IrminReference.S) =
struct

  let git_of_key key =
    Git.SHA1.of_string (K.to_raw key)

  let key_of_git key =
    K.of_raw (Git.SHA1.to_string key)

  let files = Lwt_pool.create 50 (fun () -> return_unit)

  let with_file fn t k =
    match X.kind with
    | `Memory -> fn t k
    | `Disk   -> Lwt_pool.use files (fun () -> fn t k)

  module XInternal = struct

    module type V = sig
      type t
      val type_eq: Git.Object_type.t -> bool
      val to_git: G.t -> t -> [`Value of Git.Value.t Lwt.t | `Key of Git.SHA1.t]
      val of_git: Git.SHA1.t -> Git.Value.t -> t option
    end

    module AO (V: V) = struct

      type t = G.t

      type key = K.t

      type value = V.t

      let create () =
        G.create ?root:X.root ()

      let mem t key =
        Log.debugf "Node.mem %s" (K.to_string key);
        let key = git_of_key key in
        G.mem t key >>= function
        | false    -> return false
        | true     ->
          with_file G.read t key >>= function
          | None   -> return false
          | Some v -> return (V.type_eq (Git.Value.type_of v))

      let read t key =
        Log.debugf "Node.read %s" (K.to_string key);
        let key = git_of_key key in
        with_file G.read t key >>= function
        | None   -> return_none
        | Some v -> return (V.of_git key v)

      let read_exn t key =
        Log.debugf "read_exn %s" (K.to_string key);
        read t key >>= function
        | None   -> fail Not_found
        | Some v -> return v

      let list t k =
        Log.debugf "Node.list %s" (IrminMisc.pretty_list K.to_string k);
        return k

      let dump t =
        Log.debugf "Node.dump";
        G.list t >>= fun keys ->
        Lwt_list.fold_left_s (fun acc k ->
            with_file G.read_exn t k >>= fun v ->
            match V.of_git k v with
            | None   -> return acc
            | Some v -> return ((key_of_git k, v) :: acc)
          ) [] keys

      let add t v =
        match V.to_git t v with
        | `Key k   -> return (key_of_git k)
        | `Value v ->
          v >>= fun v ->
          with_file G.write t v >>= fun k ->
          return (key_of_git k)

    end

    module XContents = AO (struct

        type t = B.t

        let type_eq = function
          | Git.Object_type.Blob
          | Git.Object_type.Tag -> true
          | _ -> false

        let of_git k b =
          Log.debugf "Contents.of_git: %S" (Git.Value.pretty b);
          match b with
          | Git.Value.Blob b -> Some (B.of_string (Git.Blob.to_string b))
          | Git.Value.Tag _  -> None (* XXX: deal with tag objects *)
          | _                -> None

        let to_git _ b =
          Log.debugf "Contents.to_git %S" (B.to_string b);
          let value = Git.Value.Blob (Git.Blob.of_string (B.to_string b)) in
          `Value (return value)

      end)

    module XNode = AO(struct

        type t = K.t IrminNode.t

        module X = IrminNode.S(K)

        let type_eq = function
          | Git.Object_type.Blob
          | Git.Object_type.Tree -> true
          | _ -> false

        (* Name of the file containing the node contents. *)
        let contents_child = ".contents"

        let of_git k v =
          Log.debugf "Node.of_git %s" (Git.Value.pretty v);
          match v with
          | Git.Value.Blob _ ->
            (* Create a dummy leaf node to hold contents. *)
            let key = key_of_git k in
            Some (IrminNode.leaf key)
          | Git.Value.Tree t ->
            let t = List.map ~f:(fun e -> Git.Tree.(e.name, key_of_git e.node)) t in
            let contents, succ = List.partition_tf ~f:(fun (n,_) -> n = contents_child) t in
            let contents = match contents with
              | []       -> None
              | [(_, k)] -> Some k
              |  _  -> assert false in
            let succ = String.Map.of_alist_exn succ in
            Some { IrminNode.contents; succ }
          | _ -> None

        let to_git t node =
          Log.debugf "Node.to_git %s" (X.to_string node);
          let mktree entries =
            let entries = Map.to_alist entries in
            `Value (
              Lwt_list.map_p (fun (name, key) ->
                  let node = git_of_key key in
                  (* XXX: handle exec files. *)
                  let file () = return { Git.Tree.perm = `Normal; name; node } in
                  let dir ()  = return { Git.Tree.perm = `Dir   ; name; node } in
                  catch
                    (fun () -> with_file G.read t node)
                    (function Zlib.Error _ -> return_none | e -> fail e)
                  >>= function
                  | None   -> dir () (* on import, the children nodes migh not
                                        have been loaded properly yet. *)
                  | Some v ->
                    match Git.Value.type_of v with
                    | Git.Object_type.Blob -> file ()
                    | Git.Object_type.Tree -> dir ()
                    | _                    -> fail (Failure "Node.to_git")
                ) entries >>= fun entries ->
              return (Git.Value.Tree entries)
            ) in
          if IrminNode.is_leaf node then (
            (* This is a dummy leaf node. Do nothing. *)
            Log.debugf "Skiping %s" (X.to_string node);
            `Key (git_of_key (IrminNode.contents_exn node))
          ) else match node.IrminNode.contents with
            | None     -> mktree node.IrminNode.succ
            | Some key ->
              (* This is an extended node (ie. with child and contents).
                 Store the node contents in a dummy `.contents` file. *)
              mktree (Map.add node.IrminNode.succ contents_child key)
      end)

    module XCommit = AO(struct

        type t = K.t IrminCommit.t

        module X = IrminCommit.S(K)

        let type_eq = function
          | Git.Object_type.Commit -> true
          | _ -> false

        let of_git k v =
          Log.debugf "Commit.of_git %s" (Git.Value.pretty v);
          match v with
          | Git.Value.Commit { Git.Commit.tree; parents; author; message } ->
            let commit_key_of_git k = key_of_git (Git.SHA1.of_commit k) in
            let node_key_of_git k = key_of_git (Git.SHA1.of_tree k) in
            let parents = List.map ~f:commit_key_of_git parents in
            let node = Some (node_key_of_git tree) in
            let id = author.Git.User.name in
            let date = match String.split ~on:' ' author.Git.User.date with
              | [date;_] -> Int64.of_string date
              | _        -> 0L in
            let origin = IrminOrigin.create ~date ~id "%s" message in
            Some { IrminCommit.node; parents; origin }
          | _ -> None

        let to_git _ c =
          Log.debugf "Commit.to_git %s" (X.to_string c);
          let { IrminCommit.node; parents; origin } = c in
          match node with
          | None      -> failwith "Commit.to_git: not supported"
          | Some node ->
            let git_of_commit_key k = Git.SHA1.to_commit (git_of_key k) in
            let git_of_node_key k = Git.SHA1.to_tree (git_of_key k) in
            let tree = git_of_node_key node in
            let parents = List.map ~f:git_of_commit_key parents in
            let date = Int64.to_string (IrminOrigin.date origin) ^ " +0000" in
            let author =
              Git.User.({ name  = IrminOrigin.id origin;
                          email = "irminsule@openmirage.org";
                          date;
                        }) in
            let message = IrminOrigin.message origin in
            let commit = {
              Git.Commit.tree; parents;
              author; committer = author;
              message } in
            let value = Git.Value.Commit commit in
            `Value (return value)

      end)

    include IrminValue.Mux(K)(B)(XContents)(XNode)(XCommit)

  end

  module XReference = struct

    module W = IrminWatch.Make(R)(K)

    type t = {
      t: G.t;
      w: W.t;
    }

    type key = R.t

    type value = K.t

    let ref_of_git r =
      R.of_string (Git.Reference.to_string r)

    let git_of_ref r =
      Git.Reference.of_string (R.to_string r)

    let mem { t } r =
      G.mem_reference t (git_of_ref r)

    let key_of_git k = key_of_git (Git.SHA1.of_commit k)

    let read { t } r =
      G.read_reference t (git_of_ref r) >>= function
      | None   -> return_none
      | Some k -> return (Some (key_of_git k))

  let create () =
    let (/) = Filename.concat in
    G.create ?root:X.root () >>= fun t ->
    let git_root = G.root t / ".git" in
    let ref_of_file file =
      match String.chop_prefix ~prefix:(git_root / "") file with
      | None   -> None
      | Some r -> Some (R.of_raw r) in
    let w = W.create () in
    let t = { t; w } in
    if X.kind = `Disk then
      W.listen_dir w (git_root / "refs") ref_of_file (read t);
    return t

    let read_exn { t } r =
      Log.debugf "read_exn %s" (R.to_string r);
      G.read_reference_exn t (git_of_ref r) >>= fun k ->
      return (key_of_git k)

    let list { t } _ =
      G.references t >>= fun refs ->
      return (List.map ~f:ref_of_git refs)

    let dump { t } =
      G.references t >>= fun refs ->
      Lwt_list.map_p (fun r ->
          G.read_reference_exn t r >>= fun k ->
          return (ref_of_git r, key_of_git k)
        ) refs

    let git_of_key k = Git.SHA1.to_commit (git_of_key k)

    let update t r k =
      let gr = git_of_ref r in
      let gk = git_of_key k in
      G.write_head t.t (Git.Reference.Ref gr) >>= fun () ->
      G.write_reference t.t gr gk >>= fun () ->
      W.notify t.w r (Some k);
      if X.kind = `Disk && not X.bare then
        G.write_cache t.t gk
      else
        return_unit

    let remove t r =
      G.remove_reference t.t (git_of_ref r) >>= fun () ->
      W.notify t.w r None;
      return_unit

    let watch t (r:key): value Lwt_stream.t =
      Log.debugf "watch %s" (R.to_string r);
      IrminMisc.lift_stream (
        read t r >>= fun k ->
        return (W.watch t.w r k)
      )

    module Key = R

    module Value = K

  end

  include Irmin.Make(K)(B)(R)(XInternal)(XReference)

end

module Make
    (K: IrminKey.S)
    (C: IrminContents.S)
    (R: IrminReference.S) =
struct

  let create ?root ~kind ~bare () =
    let module X = struct
      let root = root
      let kind = kind
      let bare = bare
    end in
    let module G = (val match kind with
        | `Disk   -> (module Git_fs    : Git.Store.S)
        | `Memory -> (module Git_memory: Git.Store.S))
    in
    let module M = XMake(X)(G)(K)(C)(R) in
    (module M: Irmin.S with type Internal.key = K.t
                        and type value = C.t
                        and type Reference.key = R.t)

  let cast (module M: Irmin.S with type Internal.key = K.t
                               and type value = C.t
                               and type Reference.key = R.t) =

    (module M: Irmin.S)

end

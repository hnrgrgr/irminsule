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

open Core_kernel.Std
open Lwt

module Log = Log.Make(struct let section = "HTTP" end)

type 'a t = {
  input : Ezjsonm.t -> 'a;
  output: 'a -> Ezjsonm.t;
}

let some fn = {
  input  = Ezjsonm.get_option fn.input;
  output = Ezjsonm.option fn.output
}

let list fn = {
  input  = Ezjsonm.get_list fn.input;
  output = Ezjsonm.list fn.output;
}

let pair a b = {
  input  = Ezjsonm.get_pair a.input b.input;
  output = Ezjsonm.pair a.output b.output;
}

let bool = {
  input  = Ezjsonm.get_bool;
  output = Ezjsonm.bool;
}

let path = {
  input  = Ezjsonm.get_list Ezjsonm.get_string;
  output = Ezjsonm.list Ezjsonm.string;
}

let unit = {
  input  = Ezjsonm.get_unit;
  output = (fun () -> Ezjsonm.unit);
}

let json_headers = Cohttp.Header.of_list [
    "Content-type", "application/json"
  ]

let respond_error e =
  let json = `O [ "error", IrminMisc.json_encode (Exn.to_string e) ] in
  let body = Ezjsonm.to_string json in
  Cohttp_lwt_unix.Server.respond_string
    ~headers:json_headers
    ~status:`Internal_server_error
    ~body ()

exception Invalid

module Server (S: Irmin.S) = struct

  module K = S.Internal.Key
  let key = {
    input  = K.of_json;
    output = K.to_json;
  }

  module Contents = S.Internal.Contents
  module B = Contents.Value
  let contents = {
    input  = B.of_json;
    output = B.to_json;
  }

  module Node = S.Internal.Node
  module T = Node.Value
  let node = {
    input  = T.of_json;
    output = T.to_json;
  }

  module Commit = S.Internal.Commit
  module C = Commit.Value
  let commit = {
    input  = C.of_json;
    output = C.to_json;
  }

  module Reference = S.Reference
  module R = Reference.Key
  let reference = {
    input  = R.of_json;
    output = R.to_json;
  }

  module D = S.Dump
  let dump = {
    input  = D.of_json;
    output = D.to_json;
  }

  let origin = {
    input  = IrminOrigin.of_json;
    output = IrminOrigin.to_json;
  }

  let mk_dump key value =
    list (pair key value)

  let respond ?headers body =
    Log.debugf "%S" body;
    Cohttp_lwt_unix.Server.respond_string ?headers ~status:`OK ~body ()

  let respond_json json =
    let json = `O [ "result", json ] in
    let body = Ezjsonm.to_string json in
    respond ~headers:json_headers body

  let respond_json_stream stream =
    let (++) = Lwt_stream.append in
    let stream =
      (Lwt_stream.of_list ["["])
      ++ (Lwt_stream.map (fun j -> Ezjsonm.to_string (`O ["result", j]) ^ ",") stream)
      ++ (Lwt_stream.of_list [" {\"result\":[]}]"])
    in
    let body = Cohttp_lwt_body.of_stream stream in
    Cohttp_lwt_unix.Server.respond ~headers:json_headers ~status:`OK ~body ()

  let error fmt =
    Printf.ksprintf (fun msg ->
        failwith ("error: " ^ msg)
      ) fmt

  type 'a leaf = S.t -> string list -> Ezjsonm.t option -> 'a

  type t =
    | Fixed  of Ezjsonm.t Lwt.t leaf
    | Stream of Ezjsonm.t Lwt_stream.t leaf
    | Node   of (string * t) list

  let to_json t =
    let rec aux path acc = function
      | Fixed   _
      | Stream _ -> `String (IrminPath.to_string (List.rev path)) :: acc
      | Node c   -> List.fold_left c
                      ~f:(fun acc (s,t) -> aux (s::path) acc t)
                      ~init:acc in
    `A (List.rev (aux [] [] t))

  let child c t: t =
    let error () =
      failwith ("Unknown action: " ^ c) in
    match t with
    | Fixed _
    | Stream _ -> error ()
    | Node l   ->
      try List.Assoc.find_exn l c
      with Not_found -> error ()

  let bl t = S.Internal.contents (S.internal t)
  let no t = S.Internal.node (S.internal t)
  let co t = S.Internal.commit (S.internal t)
  let re t = S.reference t
  let t x = x

  let mk0p name = function
    | [] -> ()
    | p  -> error "%s: non-empty path (%s)" name (IrminPath.to_string p)

  let mk0b name = function
    | None   -> ()
    | Some _ -> error "%s: non-empty body" name

  let mk1p name i path =
    match path with
    | [x] -> i.input (`String x)
    | []  -> error "%s: empty path" name
    | l   -> error "%s: %s is an invalid path" name (IrminPath.to_string l)

  let mk1b name i = function
    | None   -> error "%s: empty body" name
    | Some b  -> i.input b

  let mk2b name i j = function
    | None   -> error "%s: empty body" name
    | Some b -> (pair i j).input b

  let mklp name i1 path =
    i1.input (Ezjsonm.strings path)

  (* no arguments, fixed answer *)
  let mk0p0bf name fn db o =
    name,
    Fixed (fun t path params ->
        mk0p name path;
        mk0b name params;
        fn (db t) >>= fun r ->
        return (o.output r)
      )

  (* 1 argument in the path, fixed answer *)
  let mk1p0bf name fn db i1 o =
    name,
    Fixed (fun t path params ->
        let x = mk1p name i1 path in
        mk0b name params;
        fn (db t) x >>= fun r ->
        return (o.output r)
      )

  (* list of arguments in the path, fixed answer *)
  let mklp0bf name fn db i1 o =
    name,
    Fixed (fun t path params ->
        let x = mklp name i1 path in
        mk0b name params;
        fn (db t) x >>= fun r ->
        return (o.output r)
      )

  (* 1 argument in the body *)
  let mk0p1bf name fn db i1 o =
    name,
    Fixed (fun t path params ->
        mk0p name path;
        let x = mk1b name i1 params in
        fn (db t) x >>= fun r ->
        return (o.output r)
      )

  (* 1 argument in the path, 1 argument in the body, fixed answer *)
  let mk1p1bf name fn db i1 i2 o =
    name,
    Fixed (fun t path params ->
        let x1 = mk1p name i1 path in
        let x2 = mk1b name i2 params in
        fn (db t) x1 x2 >>= fun r ->
        return (o.output r)
      )

  (* list of arguments in the path, 1 argument in the body, fixed answer *)
  let mklp1bf name fn db i1 i2 o =
    name,
    Fixed (fun t path params ->
        let x1 = mklp name i1 path in
        let x2 = mk1b name i2 params in
        fn (db t) x1 x2 >>= fun r ->
        return (o.output r)
      )

  (* list of arguments in the path, 2 arguments in the body, fixed answer *)
  let mklp2bf name fn db i1 i2 i3 o =
    name,
    Fixed (fun t path params ->
        let x1 = mklp name i1 path in
        let x2, x3 = mk2b name i2 i3 params in
        fn (db t) x1 x2 x3 >>= fun r ->
        return (o.output r)
      )

  (* list of arguments in the path, no body, streamed response *)
  let mklp0bs name fn db i1 o =
    name,
    Stream (fun t path params ->
        let x1 = mklp name i1 path in
        let stream = fn (db t) x1 in
        Lwt_stream.map (fun r -> o.output r) stream
      )

  let contents_store = Node [
      mk1p0bf "read" Contents.read bl key (some contents);
      mk1p0bf "mem"  Contents.mem  bl key bool;
      mklp0bf "list" Contents.list bl (list key) (list key);
      mk0p1bf "add"  Contents.add  bl contents key;
      mk0p0bf "dump" Contents.dump bl (mk_dump key contents);
  ]

  let node_store = Node [
      mk1p0bf "read" Node.read no key (some node);
      mk1p0bf "mem"  Node.mem  no key bool;
      mklp0bf "list" Node.list no (list key) (list key);
      mk0p1bf "add"  Node.add  no node key;
      mk0p0bf "dump" Node.dump no (mk_dump key node);
  ]

  let commit_store = Node [
      mk1p0bf "read" Commit.read co key (some commit);
      mk1p0bf "mem"  Commit.mem  co key bool;
      mklp0bf "list" Commit.list co (list key) (list key);
      mk0p1bf "add"  Commit.add  co commit key;
      mk0p0bf "dump" Commit.dump co (mk_dump key commit);
  ]

  let reference_store = Node [
      mklp0bf "read"   Reference.read   re reference (some key);
      mklp0bf "mem"    Reference.mem    re reference bool;
      mklp0bf "list"   Reference.list   re (list reference) (list reference);
      mklp1bf "update" Reference.update re reference key unit;
      mklp0bf "remove" Reference.remove re reference unit;
      mk0p0bf "dump"   Reference.dump   re (mk_dump reference key);
      mklp0bs "watch"  Reference.watch  re reference key;
  ]

  let store =
    let s_update t p o c = S.update t ?origin:o p c in
    let s_remove t p o = S.remove t ?origin:o p in
    Node [
      mklp0bf "read"     S.read     t path (some contents);
      mklp0bf "mem"      S.mem      t path bool;
      mk0p1bf "list"     S.list     t (list path) (list path);
      mklp2bf "update"   s_update   t path (some origin) contents unit;
      mklp1bf "remove"   s_remove   t path (some origin) unit;
      mk0p0bf "dump"     S.dump     t (mk_dump path contents);
      mk0p0bf "snapshot" S.snapshot t key;
      mk1p0bf "revert"   S.revert   t key unit;
      mklp0bf "export"   S.export   t (list key) dump;
      mk1p1bf "import"   S.import   t reference dump unit;
      mklp0bs "watch"    S.watch    t path (pair path key);
      "contents"  , contents_store;
      "node"  , node_store;
      "commit", commit_store;
      "ref"   , reference_store;
  ]

  let process t req body path =
    begin match Cohttp.Request.meth req with
      | `DELETE
      | `GET       -> return_none
      | `POST ->
        Cohttp_lwt_body.length body >>= fun (len, body) ->
        if len = 0 then
          return_none
        else begin
          Cohttp_lwt_body.to_string body >>= fun b ->
          Log.debugf "process: length=%d body=%S" len b;
          try match Ezjsonm.from_string b with
            | `O l ->
              if List.Assoc.mem l "params" then
                return (List.Assoc.find l "params")
              else
                failwith "process: wrong request"
            | _    ->
              failwith "Wrong parameters"
          with _ ->
            Log.debugf "process: not a valid JSON body %S" b;
            fail Invalid
        end
      | _ -> fail Invalid
    end >>= fun params ->
    let rec aux actions path =
      match path with
      | []      -> respond_json (to_json actions)
      | h::path ->
        match child h actions with
        | Fixed fn  -> fn t path params >>= respond_json
        | Stream fn -> respond_json_stream (fn t path params)
        | actions   -> aux actions path in
    aux store path

end

let start_server (type t) (module S: Irmin.S with type t = t) (t:t) uri =
  let address = Uri.host_with_default ~default:"localhost" uri in
  let port = match Uri.port uri with
    | None   -> 8080
    | Some p -> p in
  let module Server = Server(S) in
  printf "Server started on port %d.\n%!" port;
  let callback conn_id req body =
    let path = Uri.path (Cohttp.Request.uri req) in
    Log.infof "Request received: PATH=%s" path;
    let path = String.split path ~on:'/' in
    let path = List.filter ~f:((<>) "") path in
    catch
      (fun () -> Server.process t req body path)
      (fun e  -> respond_error e) in
  let conn_closed conn_id () =
    Log.debugf "Connection %s closed!" (Cohttp.Connection.to_string conn_id) in
  let config = { Cohttp_lwt_unix.Server.callback; conn_closed } in
  Cohttp_lwt_unix.Server.create ~address ~port config

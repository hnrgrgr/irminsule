(*
 * Copyright (c) 2013 Thomas Gazagnaire <thomas@gazagnaire.org>
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

open IrminLwt
open OUnit
open Test_common

let debug fmt = IrminMisc.debug "TEST-QUEUE" fmt

let v1 = Value.of_string "foo"
let v2 = Value.of_string ""
let v3 = Value.of_string "bar"

let t = IrminQueue.create (Dir test_db)
let test_db_1 = test_db ^ ".1"
let t1 = IrminQueue.create (Dir test_db_1)

let test_init () =
  clean test_db;
  IrminQueue.init t

let test_peek () =
  lwt () = test_init () in
  lwt () = IrminQueue.add t v1 in
  lwt () = IrminQueue.add t v2 in
  lwt v1' = IrminQueue.peek t in
  assert_value_equal "v1" v1 v1';
  Lwt.return ()

let test_list () =
  lwt () = test_init () in
  lwt nil = IrminQueue.to_list t in
  assert_valuel_equal "nil" [] nil;
  lwt () = IrminQueue.add t v1 in
  lwt v1' = IrminQueue.to_list t in
  assert_valuel_equal "v1" [v1] v1';
  lwt () = IrminQueue.add t v2 in
  lwt v1v2 = IrminQueue.to_list t in
  assert_valuel_equal "v1-v2" [v1; v2] v1v2;
  Lwt.return ()

let test_take () =
  lwt () = test_init () in
  lwt () = IrminQueue.add t v1 in
  lwt () = IrminQueue.add t v2 in
  lwt v1v2 = IrminQueue.to_list t in
  assert_valuel_equal "v1v2" [v1;v2] v1v2;
  lwt v1' = IrminQueue.take t in
  assert_value_equal "v1" v1 v1';
  lwt v2l = IrminQueue.to_list t in
  assert_valuel_equal "v2-list" [v2] v2l;
  lwt v2' = IrminQueue.take t in
  assert_value_equal "v2" v2 v2';
  lwt nil = IrminQueue.to_list t in
  assert_valuel_equal "nil" [] nil;
  Lwt.return ()

let test_clone () =
  lwt () = test_init () in
  clean test_db_1;
  lwt () = IrminQueue.add t v1 in
  lwt () = IrminQueue.add t v2 in
  lwt v1v2 = IrminQueue.to_list t in
  assert_valuel_equal "v1v2" [v1;v2] v1v2;
  lwt () = IrminQueue.clone t1 ~origin:t in
  lwt v1v2' = IrminQueue.to_list t1 in
  assert_valuel_equal "v1v2'" [v1;v2] v1v2';
  Lwt.return ()

let test_pull () =
  lwt () = test_clone () in
  lwt () = IrminQueue.add t v3 in
  let base () =
    lwt v1v2v3 = IrminQueue.to_list t in
    assert_valuel_equal "v1v2v3" [v1;v2;v3] v1v2v3;
    lwt v1v2 = IrminQueue.to_list t1 in
    assert_valuel_equal "v1v2" [v1;v2] v1v2;
    Lwt.return () in
  lwt () = base () in
  lwt () = IrminQueue.pull t ~origin:t1 in
  lwt () = base () in
  lwt () = IrminQueue.pull t1 ~origin:t in
  lwt v1v2v3 = IrminQueue.to_list t in
  assert_valuel_equal "v1v2v3" [v1;v2;v3] v1v2v3;
  lwt v1v2v3' = IrminQueue.to_list t1 in
  assert_valuel_equal "v1v2v3" [v1;v2;v3] v1v2v3';
  Lwt.return ()

let suite =
  "QUEUE",
  List.map (fun (doc,t) -> doc, fun () -> Lwt_unix.run (t ()))
    [
      "Create a fresh queue"              , test_init;
      "Peek an element from the queue"    , test_peek;
      "List all the elements in the queue", test_list;
      "Take an element from the queue"    , test_take;
      "Clone a fresh queue"               , test_clone;
      "Pull between two queues"           , test_pull;
    ]

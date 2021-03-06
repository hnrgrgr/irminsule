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

let () =
  let suite k = [
    `Quick, Test_memory.suite k;
    `Quick, Test_fs.suite k;
    `Quick, Test_git.suite k `Disk;
    `Quick, Test_git.suite k `Memory;
    `Quick, Test_dispatch.suite k [|
(*      Test_git.suite k `Disk; *)
      Test_memory.suite k;
      Test_fs.suite k;
    |];
    `Slow , Test_crud.suite k (Test_memory.suite k);
    `Slow , Test_crud.suite k (Test_fs.suite k);
    `Slow , Test_crud.suite k (Test_git.suite k `Disk);
  ] in
  Test_store.run "irminsule" (suite `String @ suite `JSON)

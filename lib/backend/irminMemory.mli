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

(** In-memory store *)

open Core_kernel.Std

module AO (K: IrminKey.S) (V: Identifiable.S):
  IrminStore.AO with type key = K.t and type value = V.t

module RW (K: IrminKey.S) (V: Identifiable.S):
  IrminStore.RW with type key = K.t and type value = V.t

module Make
    (K: IrminKey.S)
    (C: IrminContents.S)
    (R: IrminReference.S):
sig

  val create: unit -> (K.t, C.t, R.t) Irmin.t

  val cast: (K.t, C.t, R.t) Irmin.t -> (module Irmin.S)

end

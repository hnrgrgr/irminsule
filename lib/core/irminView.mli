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

(** In-memory partial views of the database, with lazy fetching. *)

open Core_kernel.Std

module Action: sig

  (** Actions performed on a view. *)
  type 'contents t =
    | Read of IrminPath.t * 'contents option
    | Write of IrminPath.t * 'contents option
    | List of IrminPath.t list * IrminPath.t list
  with bin_io, compare, sexp
  (** Operations on view. We record the result of reads to be able to
      replay them on merge. *)

  val to_string: ('a -> string) -> 'a t -> string
  (** Pretty-print an action. *)

end

module type S = sig

  include IrminStore.RW with type key = IrminPath.t

  type internal_key

  val import:
    contents:(internal_key -> value option Lwt.t) ->
    node:(internal_key ->  internal_key IrminNode.t option Lwt.t) ->
    internal_key -> t Lwt.t
  (** Create a rooted view from a database node. The (optional)
      [commit] is there to remember where this view comes from, which
      is useful when you want to 3-way merge a view back to the
      store. *)

  val export:
    contents:(value -> internal_key Lwt.t) ->
    node:(internal_key IrminNode.t -> internal_key Lwt.t) ->
    t -> internal_key Lwt.t
  (** Export the view to the database. *)

  val actions: t -> value Action.t list
  (** Return the list of actions performed on this view since its
      creation. *)

  val merge: t -> into:t -> unit IrminMerge.result Lwt.t
  (** Merge the actions done on one view into an other one. If a read
      operation doesn't return the same result, return
      [Conflict]. Only the [into] view is updated. *)

end

module Make (Store: IrminContents.STORE): S with type value = Store.value
                                             and type internal_key = Store.key

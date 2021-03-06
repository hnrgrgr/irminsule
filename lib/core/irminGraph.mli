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

(** Graphs. *)

open Core_kernel.Std

module type S = sig

(** Main signature. *)

  include Graph.Sig.I
  (** Directed graph *)

  include Graph.Oper.S with type g := t
  (** Basic operations. *)

  module Topological: sig
    val fold: (vertex -> 'a -> 'a) -> t -> 'a -> 'a
  end
  (** Topoogical traversal *)

  val vertex: t -> vertex list
  (** Get all the vertices. *)

  val edges: t -> (vertex * vertex) list
  (** Get all the relations. *)

  val closure:
    (vertex -> vertex list Lwt.t)
    -> min:vertex list
    -> max:vertex list
    -> t Lwt.t
  (** [closure min max pred] creates the clansitive closure of [max]
      using the precedence relation [pred]. The closure will not
      contain any keys before the the one specified in [min]. *)

  val output:
    Format.formatter ->
    (vertex * Graph.Graphviz.DotAttributes.vertex list) list ->
    (vertex * Graph.Graphviz.DotAttributes.edge list * vertex) list ->
    string -> unit
  (** [output ppf vertex edges name] create aand dumps the graph
      contents on [ppf]. The graph is defined by its [vertex] and
      [edges]. [name] is the name of the output graph.*)

  val min: t -> vertex list
  (** Compute the minimum vertex. *)

  val max: t -> vertex list
  (** Compute the maximun vertex. *)

  type dump = vertex list * (vertex * vertex) list
  (** Expose the graph internals. *)

  val export: t -> dump
  (** Expose the graph as a pair of vertices and edges. *)

  val import: dump -> t
  (** Import a graph. *)

  module Dump: Identifiable.S with type t = dump
  (** The base functions over graph internals. *)

end

type ('a, 'b) vertex =
  [ `Contents of 'a
  | `Node of 'a
  | `Commit of 'a
  | `Ref of 'b ]

val of_refs: 'b list -> ('a, 'b) vertex list
val to_refs: ('a, 'b) vertex list -> 'b list

val of_commits: 'a list -> ('a, 'b) vertex list
val to_commits: ('a, 'b) vertex list -> 'a list

val of_nodes: 'a list -> ('a, 'b) vertex list
val to_nodes: ('a, 'b) vertex list -> 'a list

val of_contents: 'a list -> ('a, 'b) vertex list
val to_contents: ('a, 'b) vertex list -> 'a list

val to_keys: ('a, 'b) vertex list -> 'a list

(** Build a graph. *)
module Make(K: IrminKey.S)(R: IrminReference.S): S with type V.t = (K.t, R.t) vertex

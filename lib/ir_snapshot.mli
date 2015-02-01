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

(** Manage snapshot/revert capabilities. *)

module type S = sig
  include Ir_ro.STORE
  type db
  val to_hum: t -> string
  val of_hum: db -> string -> t
  val create: db -> t Lwt.t
  val revert: db -> t -> unit Lwt.t
  val merge: db -> ?max_depth:int -> ?n:int -> t -> unit Ir_merge.result Lwt.t
  val merge_exn: db -> ?max_depth:int -> ?n:int -> t -> unit Lwt.t
  val watch: db -> key -> (key * t) Lwt_stream.t
end

module Make (S: Ir_s.STORE):
  S with type db = S.t
            and type key = S.key
            and type value = S.value
(** Add snapshot capabilities to a branch-consistent store. *)

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

open Ir_merge.OP
open Ir_misc.OP
open Printf

let (>>=) = Lwt.bind

module Log = Log.Make(struct let section = "view" end)

(***** Actions *)

module Action (P: Tc.S0) (C: Tc.S0) = struct

  type path = P.t
  type contents = C.t

  type t =
    [ `Read of (path * contents option)
    | `Write of (path * contents option)
    | `Rmdir of path
    | `List of  (path * path list) ]

  module R = Tc.Pair( P )( Tc.Option(C) )
  module W = R
  module L = Tc.Pair( P )( Tc.List(P) )

  let compare = Pervasives.compare
  let hash = Hashtbl.hash

  let equal x y = match x, y with
    | `Read x , `Read y  -> R.equal x y
    | `Write x, `Write y -> W.equal x y
    | `Rmdir x, `Rmdir y -> P.equal x y
    | `List x , `List y  -> L.equal x y
    | _ -> false

  let to_json = function
    | `Read x  -> `O [ "read" , R.to_json x ]
    | `Write x -> `O [ "write", W.to_json x ]
    | `Rmdir x -> `O [ "rmdir", P.to_json x ]
    | `List x  -> `O [ "list" , L.to_json x ]

  let of_json = function
    | `O [ "read" , x ] -> `Read  (R.of_json x)
    | `O [ "write", x ] -> `Write (W.of_json x)
    | `O [ "rmdir", x ] -> `Rmdir (P.of_json x)
    | `O [ "list" , x ] -> `List  (L.of_json x)
    | j -> Ezjsonm.parse_error j "View.Action.of_json"

  let write t buf = match t with
    | `Read x  -> R.write x (Ir_misc.tag buf 0)
    | `Write x -> W.write x (Ir_misc.tag buf 1)
    | `List x  -> L.write x (Ir_misc.tag buf 2)
    | `Rmdir x -> P.write x (Ir_misc.tag buf 3)

  let read buf = match Ir_misc.untag buf with
    | 0 -> `Read  (R.read buf)
    | 1 -> `Write (W.read buf)
    | 2 -> `List  (L.read buf)
    | 3 -> `Rmdir (P.read buf)
    | n -> Tc.Reader.error "View.Action.read (tag=%d)" n

  let size_of t = 1 + match t with
    | `Read x  -> R.size_of x
    | `Write x -> W.size_of x
    | `List x  -> L.size_of x
    | `Rmdir x -> P.size_of x

  let pretty t =
    let pretty_key = Tc.show (module P) in
    let pretty_val = Tc.show (module C) in
    let pretty_keys l = String.concat ", " (List.map pretty_key l) in
    let pretty_valo = function
      | None   -> "<none>"
      | Some x -> pretty_val x
    in
    match t with
    | `Read (p,x) -> sprintf "read  %s -> %s" (pretty_key p) (pretty_valo x)
    | `Write (p,x)-> sprintf "write %s <- %s" (pretty_key p) (pretty_valo x)
    | `List (i,o) -> sprintf "list  %s -> %s" (pretty_key i) (pretty_keys o)
    | `Rmdir p    -> sprintf "rmdir %s"       (pretty_key p)

  let prettys ts =
    let buf = Buffer.create 1024 in
    Buffer.add_string buf "Actions:\n";
    List.iter (fun a ->
        bprintf buf "- %s\n" (pretty a)
      ) ts;
    Buffer.contents buf

end

(***** views *)

module type NODE = sig
  type t
  type commit
  type node
  type contents
  module Contents: Tc.S0 with type t = contents
  module Path: Ir_path.S

  val empty: unit -> t
  val read: t -> node option Lwt.t

  val read_contents: t -> Path.step -> contents option Lwt.t
  val with_contents: t -> Path.step -> contents option -> unit Lwt.t

  val read_succ: node -> Path.step -> t option
  val with_succ: t -> Path.step -> t option -> unit Lwt.t

  val steps: t -> Path.step list Lwt.t
end

module Internal (Node: NODE) = struct

  module Path = Node.Path
  module PathSet = Ir_misc.Set(Path)

  type key = Path.t
  type value = Node.contents

  module Action = Action(Path)(Node.Contents)
  type action = Action.t

  type t = {
    view: Node.t;
    ops: action list ref;
    parents: Node.commit list ref;
  }

  module CO = Tc.Option(Node.Contents)
  module PL = Tc.List(Path)

  let empty () =
    Log.debug "empty";
    let view = Node.empty () in
    let ops = ref [] in
    let parents = ref [] in
    Lwt.return { parents; view; ops }

  let create _conf _task =
    Log.debug "create";
    empty () >>= fun t ->
    Lwt.return (fun _ -> t)

  let task _ = failwith "Not task for views"

  let sub t path =
    let rec aux node path =
      match Path.decons path with
      | None        -> Lwt.return (Some node)
      | Some (h, p) ->
        Node.read node >>= function
        | None -> Lwt.return_none
        | Some t ->
          match Node.read_succ t h with
          | None   -> Lwt.return_none
          | Some v -> aux v p
    in
    aux t.view path

  let mk_path k =
    match Path.rdecons k with
    | Some (l, t) -> l, t
    | None -> Path.empty, Path.Step.of_hum "__root__"

  let read_contents t path =
    Log.debug "read_contents %a" force (show (module Path) path);
    let path, file = mk_path path in
    sub t path >>= function
    | None   -> Lwt.return_none
    | Some n -> Node.read_contents n file

  let read t k =
    read_contents t k >>= fun v ->
    t.ops := `Read (k, v) :: !(t.ops);
    Lwt.return v

  let read_exn t k =
    read t k >>= function
    | None   -> Lwt.fail Not_found
    | Some v -> Lwt.return v

  let mem t k =
    read t k >>= function
    | None  -> Lwt.return false
    | _     -> Lwt.return true

  let list_aux t path =
    sub t path >>= function
    | None   -> Lwt.return []
    | Some n ->
      Node.steps n >>= fun steps ->
      let paths =
        List.fold_left (fun set p ->
            PathSet.add (Path.rcons path p) set
          ) PathSet.empty steps
      in
      Lwt.return (PathSet.to_list paths)

  let list t path =
    Log.debug "list %a" force (show (module Path) path);
    list_aux t path >>= fun result ->
    t.ops := `List (path, result) :: !(t.ops);
    Lwt.return result

  let iter t fn =
    Log.debug "iter";
    let rec aux = function
      | []       -> Lwt.return_unit
      | path::tl ->
        list t path >>= fun childs ->
        let todo = childs @ tl in
        fn path >>= fun () ->
        aux todo
    in
    list t Path.empty >>= aux

  let update_contents_aux t k v =
    let path, file = mk_path k in
    let rec aux view path =
      match Path.decons path with
      | None        -> Node.with_contents view file v
      | Some (h, p) ->
        Node.read view >>= function
        | None   ->
          if v = None then Lwt.return_unit
          else Lwt.fail Not_found (* XXX ?*)
        | Some n ->
          match Node.read_succ n h with
          | Some child -> aux child p
          | None ->
            if v = None then Lwt.return_unit
            else
              let child = Node.empty () in
              Node.with_succ view h (Some child) >>= fun () ->
              aux child p
    in
    aux t.view path

  let update_contents t k v =
    t.ops := `Write (k, v) :: !(t.ops);
    update_contents_aux t k v

  let update t k v =
    update_contents t k (Some v)

  let remove t k =
    update_contents t k None

  let remove_rec t k =
    match Path.decons k with
    | None -> Lwt.return_unit
    | _    ->
      let rec aux view path =
        match Path.decons path with
        | None       -> assert false
        | Some (h,p) ->
          if Path.is_empty p then
            Node.with_succ view h None
          else
            Node.read view >>= function
            | None   -> Lwt.return_unit
            | Some n ->
              match Node.read_succ n h with
              | None       -> Lwt.return_unit
              | Some child -> aux child p
      in
      t.ops := `Rmdir k :: !(t.ops);
      aux t.view k

  let watch _ _ =
    failwith "TODO: View.watch"

  let apply t a =
    Log.debug "apply %a" force (show (module Action) a);
    match a with
    | `Rmdir _ -> ok ()
    | `Write (k, v) -> update_contents t k v >>= ok
    | `Read (k, v)  ->
      read t k >>= fun v' ->
      if Tc.equal (module CO) v v' then ok ()
      else
        let str = function
          | None   -> "<none>"
          | Some c -> Tc.show (module Node.Contents) c in
        conflict "read %s: got %S, expecting %S"
          (Tc.show (module Path) k) (str v') (str v)
    | `List (l, r) ->
      list t l >>= fun r' ->
      if Tc.equal (module PL) r r' then ok ()
      else
        let one = Tc.show (module Path) in
        let many = Ir_misc.list_pretty one in
        conflict "list %s: got %s, expecting %s" (one l) (many r') (many r)

  let actions t = List.rev !(t.ops)

  let rebase t1 ~into =
    Ir_merge.iter (apply into) (actions t1) >>| fun () ->
    into.parents := Ir_misc.list_dedup (!(t1.parents) @ !(into.parents));
    ok ()

  let rebase_exn t1 ~into = rebase t1 ~into >>= Ir_merge.exn

end

module Make (S: Ir_s.STORE) = struct

  module B = Ir_bc.Make_ext(S.Private)
  module P = S.Private

  module Graph = Ir_node.Graph(P.Contents)(P.Node)
  module History = Ir_commit.History(Graph.Store)(P.Commit)

  let graph_t t = P.contents_t t, P.node_t t
  let history_t t = graph_t t, P.commit_t t

  module Contents = struct

    type key = S.t * B.Private.Contents.key

    type contents_or_key =
      | Key of key
      | Contents of B.value
      | Both of key * B.value

    type t = contents_or_key ref
    (* Same as [Contents.t] but can either be a raw contents or a key
       that will be fetched lazily. *)

    let create c =
      ref (Contents c)

    let export c =
      match !c with
      | Both ((_, k), _)
      | Key (_, k) -> k
      | Contents _ -> failwith "Contents.export"

    let key db k =
      ref (Key (db, k))

    let read t =
      match !t with
      | Both (_, c)
      | Contents c -> Lwt.return (Some c)
      | Key (db, k as key) ->
        P.Contents.read (P.contents_t db) k >>= function
        | None   -> Lwt.return_none
        | Some c ->
          t := Both (key, c);
          Lwt.return (Some c)

    let equal (x:t) (y:t) = match !x, !y with
      | (Key (_,x) | Both ((_,x),_)), (Key (_,y) | Both ((_,y),_)) ->
        P.Contents.Key.equal x y
      | (Contents x | Both (_, x)), (Contents y | Both (_, y)) ->
        P.Contents.Val.equal x y
      | _ -> false

  end

  module Node = struct

    module Path = S.Key

    module Step = Path.Step
    module StepMap = Ir_misc.Map(Path.Step)
    module StepSet = Ir_misc.Set(Path.Step)

    type contents = S.value
    type commit = S.head
    type key = S.t * P.Node.key

    (* XXX: fix code duplication with Ir_node.Graph (using
       functors?) *)
    type node = {
      contents: Contents.t StepMap.t Lazy.t;
      succ    : t StepMap.t Lazy.t;
      alist   : (Path.step * [`Contents of Contents.t | `Node of t ]) list;
    }

    and node_or_key  =
      | Key of key
      | Node of node
      | Both of key * node

    and t = node_or_key ref
    (* Similir to [Node.t] but using where all of the values can just
       be keys. *)

    let rec equal (x:t) (y:t) = match !x, !y with
      | (Key (_,x) | Both ((_,x),_)), (Key (_,y) | Both ((_,y),_)) ->
        P.Node.Key.equal x y
      | (Node x | Both (_, x)), (Node y | Both (_, y)) ->
        List.length x.alist = List.length y.alist
        && List.for_all2 (fun (s1, n1) (s2, n2) ->
            Step.equal s1 s2
            && match n1, n2 with
            | `Contents n1, `Contents n2 -> Contents.equal n1 n2
            | `Node n1, `Node n2 -> equal n1 n2
            | _ -> false) x.alist y.alist
      | _ -> false

    let mk_index alist =
      lazy (
        List.fold_left (fun (contents, succ) (l, x) ->
            match x with
            | `Contents c -> StepMap.add l c contents, succ
            | `Node n     -> contents, StepMap.add l n succ
          ) (StepMap.empty, StepMap.empty) alist
      )

    let create_node alist =
      let maps = mk_index alist in
      let contents = lazy (fst (Lazy.force maps)) in
      let succ = lazy (snd (Lazy.force maps)) in
      { contents; succ; alist }

    let create alist =
      ref (Node (create_node alist))

    let key db k =
      ref (Key (db, k))

    let both db k v =
      ref (Both ((db, k), v))

    let empty () = create []

    let import t n =
      let alist = P.Node.Val.alist n in
      let alist = List.map (fun (l, x) ->
          match x with
          | `Contents c -> (l, `Contents (Contents.key t c))
          | `Node n     -> (l, `Node (key t n))
        ) alist in
      create_node alist

    let export n =
      match !n with
      | Both ((_, k), _)
      | Key (_, k)  -> k
      | Node _ -> failwith "Node.export"

    let export_node n =
      let alist = List.map (fun (l, x) ->
          match x with
          | `Contents c -> (l, `Contents (Contents.export c))
          | `Node n     -> (l, `Node (export n))
        ) n.alist
      in
      P.Node.Val.create alist

    let read t =
      match !t with
      | Both (_, n)
      | Node n   -> Lwt.return (Some n)
      | Key (db, k) ->
        P.Node.read (P.node_t db) k >>= function
        | None   -> Lwt.return_none
        | Some n ->
          let n = import db n in
          t := Both ((db, k), n);
          Lwt.return (Some n)

    let steps t =
      Log.debug "steps";
      read t >>= function
      | None    -> Lwt.return_nil
      | Some  n ->
        let steps = ref StepSet.empty in
        List.iter (fun (l, _) -> steps := StepSet.add l !steps) n.alist;
        Lwt.return (StepSet.to_list !steps)

    let read_contents t step =
      read t >>= function
      | None   -> Lwt.return_none
      | Some t ->
        try
          StepMap.find step (Lazy.force t.contents)
          |> Contents.read
        with Not_found ->
          Lwt.return_none

    let read_succ t step =
      try Some (StepMap.find step (Lazy.force t.succ))
      with Not_found -> None

    (* FIXME code duplication with Ir_node.Make.with_contents *)
    let with_contents t step contents =
      Log.debug "with_contents %a %a"
        force (show (module Step) step)
        force (show (module Tc.Option(S.Val)) contents);
      let mk c = `Contents (Contents.create c) in
      read t >>= function
      | None   ->
        let () = match contents with
          | None   -> ()
          | Some c -> t := Node (create_node [ step, mk c ])
        in
        Lwt.return_unit
      | Some n ->
        let rec aux acc = function
          | (s, `Contents x as h) :: l ->
            if Step.equal step s then match contents with
              | None   -> List.rev_append acc l
              | Some c ->
                if Contents.equal (Contents.create c) x then n.alist
                else List.rev_append acc ((s, mk c) :: l)
            else aux (h :: acc) l
          | h::t -> aux (h :: acc) t
          | []   -> match contents with
            | None   -> n.alist
            | Some c -> List.rev ((step, mk c) :: acc)
        in
        let alist = aux [] n.alist in
        if n.alist != alist then t := Node (create_node alist);
        Lwt.return_unit

    (* FIXME: code duplication with Ir_node.Make.with_succ *)
    let with_succ t step succ =
      let mk c = `Node c in
      read t >>= function
      | None   ->
        let () = match succ with
          | None   -> ()
          | Some c -> t := Node (create_node [ step, mk c ])
        in
        Lwt.return_unit
      | Some n ->
        let rec aux acc = function
          | (s, `Node x as h) :: l ->
            if Step.equal step s then match succ with
              | None   -> List.rev_append acc l
              | Some c ->
                if equal c x then n.alist
                else List.rev_append acc ((s, mk c) :: l)
            else aux (h :: acc) l
          | h::t -> aux (h :: acc) t
          | []   -> match succ with
            | None   -> n.alist
            | Some c -> List.rev ((step, mk c) :: acc)
        in
        let alist = aux [] n.alist in
        if n.alist != alist then t := Node (create_node alist);
        Lwt.return_unit

    module Contents = P.Contents.Val

  end

  include Internal(Node)

  type db = S.t

  let create_with_parents parents =
    Log.debug "create_with_parents";
    let view = Node.empty () in
    let ops = ref [] in
    let parents = ref parents in
    { parents; view; ops }

  let import db ~parents key =
    Log.debug "import %a" force (show (module P.Node.Key) key);
    begin P.Node.read (P.node_t db) key >>= function
    | None   -> Lwt.return (Node.empty ())
    | Some n -> Lwt.return (Node.both db key (Node.import db n))
    end >>= fun view ->
    let ops = ref [] in
    let parents = ref parents in
    Lwt.return { parents; view; ops }

  let export db t =
    Log.debug "export";
    let node n = P.Node.add (P.node_t db) (Node.export_node n) in
    let todo = Stack.create () in
    let rec add_to_todo n =
      match !n with
      | Node.Both _
      | Node.Key _  -> ()
      | Node.Node x ->
        (* 1. we push the current node job on the stack. *)
        Stack.push (fun () ->
            node x >>= fun k ->
            n := Node.Key (db, k);
            Lwt.return_unit
          ) todo;
        (* 2. we push the contents job on the stack. *)
        List.iter (fun (_, x) ->
            match x with
            | `Node _ -> ()
            | `Contents c ->
              match !c with
              | Contents.Both _
              | Contents.Key _       -> ()
              | Contents.Contents x  ->
                Stack.push (fun () ->
                    P.Contents.add (P.contents_t db) x >>= fun k ->
                    c := Contents.Key (db, k);
                    Lwt.return_unit
                  ) todo
          ) x.Node.alist;
        (* 3. we push the children jobs on the stack. *)
        List.iter (fun (_, x) ->
            match x with
            | `Contents _ -> ()
            | `Node n ->
              Stack.push (fun () -> add_to_todo n; Lwt.return_unit) todo
          ) x.Node.alist;
    in
    let rec loop () =
      let task =
        try Some (Stack.pop todo)
        with Stack.Empty -> None
      in
      match task with
      | None   -> Lwt.return_unit
      | Some t -> t () >>= loop
    in
    add_to_todo t.view;
    loop () >>= fun () ->
    Lwt.return (Node.export t.view)

  let of_path db path =
    Log.debug "of_path %a" force (show (module Path) path);
    begin S.head db >>= function
      | None   -> Lwt.return_nil
      | Some h -> Lwt.return [h]
    end >>= fun parents ->
    P.read_node db path >>= function
    | None   -> Lwt.return (create_with_parents parents)
    | Some n -> import db ~parents n

  let update_path db path view =
    Log.debug "update_path %a" force (show (module Path) path);
    export db view >>= fun node ->
    P.update_node db path node

  let rebase_path db path view =
    Log.debug "rebase_path %a" force (show (module Path) path);
    of_path db path >>= fun head_view ->
    rebase view ~into:head_view >>| fun () ->
    update_path db path head_view >>= fun () ->
    ok ()

  let rebase_path_exn db path view =
    rebase_path db path view >>= Ir_merge.exn

  let merge_path db ?max_depth ?n path view =
    Log.debug "merge_path %a" force (show (module Path) path);
    P.read_node db Path.empty >>= function
    | None           -> update_path db path view >>= ok
    | Some head_node ->
      (* First, we check than we can rebase the view on the current
         HEAD. *)
      of_path db path >>= fun head_view ->
      rebase view ~into:head_view >>| fun () ->
      (* Now that we know that rebasing is possible, we discard the
         result and proceed as a normal merge, ie. we apply the view
         on a branch, and we merge the branch back into the store. *)
      export db view >>= fun view_node ->
      (* Create a commit with the contents of the view *)
      Graph.add_node (graph_t db) head_node path view_node >>= fun new_node ->
      match !(view.parents) with
      | [] ->
        Log.debug "No parents!";
        rebase_path db path view
      | parents ->
        Log.debug "Parents: %a" force (shows (module S.Head) parents);
        History.create (history_t db) ~node:new_node ~parents >>= fun k ->
        S.merge_head db ?max_depth ?n k

  let merge_path_exn db ?max_depth ?n path t =
    merge_path db ?max_depth ?n path t >>= Ir_merge.exn

end

module type S = sig
  include Ir_rw.HIERARCHICAL
  val empty: unit -> t Lwt.t
  val rebase: t -> into:t -> unit Ir_merge.result Lwt.t
  val rebase_exn: t -> into:t -> unit Lwt.t
  type db
  val of_path: db -> key -> t Lwt.t
  val update_path: db -> key -> t -> unit Lwt.t
  val rebase_path: db -> key -> t -> unit Ir_merge.result Lwt.t
  val rebase_path_exn: db -> key -> t -> unit Lwt.t
  val merge_path: db -> ?max_depth:int -> ?n:int -> key -> t ->
    unit Ir_merge.result Lwt.t
  val merge_path_exn: db -> ?max_depth:int -> ?n:int -> key -> t -> unit Lwt.t
  module Action: sig
    type t =
      [ `Read of (key * value option)
      | `Write of (key * value option)
      | `Rmdir of key
      | `List of (key * key list) ]
    include Tc.S0 with type t := t
    val pretty: t -> string
    val prettys: t list -> string
  end
  val actions: t -> Action.t list
end

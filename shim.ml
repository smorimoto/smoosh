open Ctypes
open Foreign
open Dash
open Fsh

let skip = Command ([],[],[])

let var_type vstype w = 
  match vstype with
 | 0x00 -> (* VSNORMAL ${var} *) Normal
 | 0x02 -> (* VSMINUS ${var-text} *) Default w
 | 0x12 -> (* VSMINUS ${var:-text} *) NDefault w
 | 0x03 -> (* VSPLUS ${var+text} *) Alt w
 | 0x13 -> (* VSPLUS ${var:+text} *) NAlt w
 | 0x04 -> (* VSQUESTION ${var?message} *) Error w
 | 0x14 -> (* VSQUESTION ${var:?message} *) NError w
 | 0x05 -> (* VSASSIGN ${var=text} *) Assign w
 | 0x15 -> (* VSASSIGN ${var:=text} *) NAssign w
 | 0x06 -> (* VSTRIMRIGHT ${var%pattern} *) Substring (Suffix,Shortest,w)
 | 0x07 -> (* VSTRIMRIGHTMAX ${var%%pattern} *) Substring (Suffix,Longest,w)
 | 0x08 -> (* VSTRIMLEFT ${var#pattern} *) Substring (Prefix,Shortest,w)
 | 0x09 -> (* VSTRIMLEFTMAX ${var##pattern} *) Substring (Prefix,Longest,w)
 | 0x0a -> (* VSLENGTH ${#var}) *) Length
 | vs -> failwith ("Unknown VSTYPE: " ^ string_of_int vs)

let rec join (ws:words list) : words =
  match ws with
  | [] -> []
  | [w] -> w
  | []::ws -> join ws
  | w1::w2::ws -> w1 @ [F] @ join (w2::ws)

let rec of_node (n : node union ptr) : stmt =
  match (n @-> node_type) with
  (* NCMD *)
  | 0  ->
     let n = n @-> node_ncmd in
     Command (to_assigns (getf n ncmd_assign),
              join (to_args (getf n ncmd_args)),
              redirs (getf n ncmd_redirect))
  (* NPIPE *)
  | 1 ->
     let n = n @-> node_npipe in
     Pipe (getf n npipe_backgnd <> 0,
           List.map of_node (nodelist (getf n npipe_cmdlist)))
  (* NREDIR *)
  | 2  -> let (c,redirs) = of_nredir n in Redir (c,redirs)
  (* NBACKGND *)
  | 3  -> let (c,redirs) = of_nredir n in Background (c,redirs)
  (* NSUBSHELL *)
  | 4  -> let (c,redirs) = of_nredir n in Subshell (c,redirs)
  (* NAND *)
  | 5  -> let (l,r) = of_binary n in And (l,r)
  (* NOR *)
  | 6  -> let (l,r) = of_binary n in Or (l,r)
  (* NSEMI *)
  | 7  -> let (l,r) = of_binary n in Semi (l,r)
  (* NIF *)
  | 8  ->
     let n = n @-> node_nif in
     let else_part = getf n nif_elsepart in
     If (of_node (getf n nif_test),
         of_node (getf n nif_ifpart),
         if nullptr else_part
         then skip
         else of_node else_part)
  (* NWHILE *)
  | 9  -> let (t,b) = of_binary n in While (t,b)
  (* NUNTIL *)
  | 10 -> let (t,b) = of_binary n in While (Not t,b)
  (* NFOR *)
  | 11 ->
     let n = n @-> node_nfor in
     For (getf n nfor_var,
          to_arg (getf n nfor_args @-> node_narg),
          of_node (getf n nfor_body))
  (* NCASE *)
  | 12 ->
     let n = n @-> node_ncase in
     Case (to_arg (getf n ncase_expr @-> node_narg),
           List.map
             (fun (pattern,body) -> (to_arg (pattern @-> node_narg), of_node body))
             (caselist (getf n ncase_cases)))
  (* NDEFUN *)
  | 14 ->
     let n = n @-> node_ndefun in
     Defun (getf n ndefun_text,
            of_node (getf n ndefun_body))
  (* NNOT *)
  | 25 -> Not (of_node (getf (n @-> node_nnot) nnot_com))
  | nt -> failwith ("Unexpected top level node_type " ^ string_of_int nt)

and of_nredir (n : node union ptr) =
  let n = n @-> node_nredir in
  (of_node (getf n nredir_n), redirs (getf n nredir_redirect))

and redirs (n : node union ptr) =
  if nullptr n
  then []
  else
    let mk_file ty =
      let n = n @-> node_nfile in
      File (ty,getf n nfile_fd,to_arg (getf n nfile_fname @-> node_narg)) in
    let mk_dup ty =
      let n = n @-> node_ndup in
      Dup (ty,getf n ndup_fd,getf n ndup_dupfd) in
    let mk_here ty =
      let n = n @-> node_nhere in
      Heredoc (ty,getf n nhere_fd,to_arg (getf n nhere_doc @-> node_narg)) in
    let h = match n @-> node_type with
      (* NTO *)
      | 16 -> mk_file To
      (* NCLOBBER *)
      | 17 -> mk_file Clobber
      (* NFROM *)
      | 18 -> mk_file From
      (* NFROMTO *)
      | 19 -> mk_file FromTo
      (* NAPPEND *)
      | 20 -> mk_file Append
      (* NTOFD *)      
      | 21 -> mk_dup ToFD
      (* NFROMFD *)              
      | 22 -> mk_dup FromFD
      (* NHERE quoted heredoc---no expansion)*)
      | 23 -> mk_here Here
      (* NXHERE unquoted heredoc (param/command/arith expansion) *)
      | 24 -> mk_here XHere
      | nt -> failwith ("unexpected node_type in redirlist: " ^ string_of_int nt)
    in
    h :: redirs (getf (n @-> node_nfile) nfile_next)

and of_binary (n : node union ptr) =
  let n = n @-> node_nbinary in
  (of_node (getf n nbinary_ch1), of_node (getf n nbinary_ch2))

and to_arg (n : narg structure) : words =
  let a,s,bqlist,stack = parse_arg (explode (getf n narg_text)) (getf n narg_backquote) [] in
  (* we should have used up the string and have no backquotes left in our list *)
  assert (s = []);
  assert (nullptr bqlist);
  assert (stack = []);
  a  

and parse_arg (s : char list) (bqlist : nodelist structure ptr) stack =
  match s,stack with
  | [],[] -> [],[],bqlist,[]
  | [],`CTLVar::_ -> failwith "End of string before CTLENDVAR"
  | [],`CTLAri::_ -> failwith "End of string before CTLENDARI"
  | [],`CTLQuo::_ -> failwith "End of string before CTLQUOTEMARK"
  (* CTLESC *)
  | '\129'::c::s,_ -> arg_char (S (Char.escaped c)) s bqlist stack
  (* CTLVAR *)
  | '\130'::t::s,_ ->
     let var_name,s = Dash.split_at (fun c -> c = '=') s in
     let t = int_of_char t in
     let v,s,bqlist,stack = match t land 0x0f, s with
     (* VSNORMAL and VSLENGTH get special treatment

     neither ever gets VSNUL
     VSNORMAL is terminated just with the =, without a CTLENDVAR *)
     (* VSNORMAL *)
     | 0x1,'='::s ->
        K (Param (implode var_name, Normal)),s,bqlist,stack
     (* VSLENGTH *)
     | 0xa,'='::'\131'::s ->
        K (Param (implode var_name, Length)),s,bqlist,stack
     | 0x1,c::_ | 0xa,c::_ ->
        failwith ("Missing CTLENDVAR for VSNORMAL/VSLENGTH, found " ^ Char.escaped c)
     (* every other VSTYPE takes mods before CTLENDVAR *)
     | vstype,'='::s ->
        let w,s,bqlist,stack' = parse_arg s bqlist (`CTLVar::stack) in
        K (Param (implode var_name, var_type vstype w)), s, bqlist, stack'
     | _,c::_ -> failwith ("Expected '=' terminating variable name, found " ^ Char.escaped c)
     | _,[] -> failwith "Expected '=' terminating variable name, found EOF"
     in
     arg_char v s bqlist stack
  (* CTLENDVAR *)
  | '\131'::s,`CTLVar::stack' -> [],s,bqlist,stack'
  | '\131'::_,`CTLAri::_ -> failwith "Saw CTLENDVAR before CTLENDARI"
  | '\131'::_,`CTLQuo::_ -> failwith "Saw CTLENDVAR before CTLQUOTEMARK"
  | '\131'::_,[] -> failwith "Saw CTLENDVAR outside of CTLVAR"
  (* CTLBACKQ *)
  | '\132'::s,_ ->
     if nullptr bqlist
     then failwith "Saw CTLBACKQ but bqlist was null"
     else arg_char (K (Backtick (of_node (bqlist @-> nodelist_n)))) s (bqlist @-> nodelist_next) stack
  (* CTLARI *)
  | '\134'::s,_ ->
     let a,s,bqlist,stack' = parse_arg s bqlist (`CTLAri::stack) in
     assert (stack = stack');
     arg_char (K (Arith ([],a))) s bqlist stack'
  (* CTLENDARI *)
  | '\135'::s,`CTLAri::stack' -> [],s,bqlist,stack'
  | '\135'::_,`CTLVar::_' -> failwith "Saw CTLENDARI before CTLENDVAR"
  | '\135'::_,`CTLQuo::_' -> failwith "Saw CTLENDARI before CTLQUOTEMARK"
  | '\135'::_,[] -> failwith "Saw CTLENDARI outside of CTLARI"
  (* CTLQUOTEMARK *)
  | '\136'::s,`CTLQuo::stack' -> [],s,bqlist,stack'
  | '\136'::s,_ ->
     let a,s,bqlist,stack' = parse_arg s bqlist (`CTLQuo::stack) in
     assert (stack' = stack);
     arg_char (K (Quote a)) s bqlist stack'
  (* tildes *)
  | '~'::s,stack ->
     let uname,s' = parse_tilde [] s in
     begin
       match uname with 
       | None -> arg_char (K Tilde) s bqlist stack
       | Some user -> arg_char (K (TildeUser user)) s bqlist stack
     end
  (* ordinary character *)
  | c::s,_ -> arg_char (S (String.make 1 c)) s bqlist stack

and parse_tilde acc = 
  let ret = if acc = [] then None else Some (implode acc) in
  function
  | [] -> (ret , [])
  (* CTLESC *)
  | '\129'::_ as s -> None, s
  (* CTLQUOTEMARK *)
  | '\136'::_ as s -> None, s
  (* terminal: CTLENDVAR, /, : *)
  | '\131'::_ as s -> ret, s
  | ':'::_ as s -> ret, s
  | '/'::_ as s -> ret, s
  (* ordinary char *)
  | c::s' -> parse_tilde (acc @ [c]) s'  
              
and arg_char c s bqlist stack =
  let a,s,bqlist,stack = parse_arg s bqlist stack in
  (c::a,s,bqlist,stack)

and to_assign v = function
  | [] -> failwith ("Never found an '=' sign in assignment, got " ^ v)
  | S "=" :: a -> (v,a)
  | (S c) :: a -> to_assign (v ^ c) a
  | _ -> failwith "Unexpected special character in assignment"
    
and to_assigns n = List.map (to_assign "") (to_args n)
    
and to_args (n : node union ptr) : words list =
  if nullptr n
  then [] 
  else (assert (n @-> node_type = 15);
        let n = n @-> node_narg in
        to_arg n::to_args (getf n narg_next))
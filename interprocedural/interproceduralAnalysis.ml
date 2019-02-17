(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open Core

open Ast
open Pyre
open Statement

module Json = Yojson.Safe
module Kind = AnalysisKind
module Result = InterproceduralResult


let analysis_failed step ~exn callable ~message =
  let callable = (callable :> Callable.t) in
  Log.error
    "%s in step %s while analyzing %s.\nException %s\nBacktrace: %s"
    message
    (Fixpoint.show_step step)
    (Callable.show callable)
    (Exn.to_string exn)
    (Printexc.get_backtrace ());
  raise exn


let get_empty_model (type a) (kind: <model:a;..> Result.storable_kind) : a =
  (* Existentially abstract unspecified analysis data *)
  let Result.ModelPart k1 = Result.ModelPart kind in
  let module Analysis = (val (Result.get_analysis k1)) in
  Analysis.empty_model


let get_obscure_model (type a) (kind: <model:a;..> Result.storable_kind) : a =
  (* Existentially abstract unspecified analysis data *)
  let Result.ModelPart k1 = Result.ModelPart kind in
  let module Analysis = (val (Result.get_analysis k1)) in
  Analysis.obscure_model


let get_obscure_models analyses =
  let get_analysis_specific_obscure_model map abstract_analysis =
    let Result.Analysis { kind; analysis; } = abstract_analysis in
    let module Analysis = (val analysis) in
    let obscure_model = Analysis.obscure_model in
    Kind.Map.add (Kind.abstract kind) (Result.Pkg { kind = ModelPart kind; value = obscure_model; })
      map
  in
  let models = List.fold ~f:get_analysis_specific_obscure_model ~init:Kind.Map.empty analyses in
  Result.{
    models;
    is_obscure = true;
  }



let non_fixpoint_witness
    (type a)
    (kind: <model:a;..> Result.storable_kind)
    ~(iteration:int)
    ~(previous:a)
    ~(next:a) =
  (* Existentially abstract unspecified analysis data *)
  let Result.ModelPart k1 = Result.ModelPart kind in
  let module Analysis = (val (Result.get_analysis k1)) in
  if Analysis.reached_fixpoint ~iteration ~previous ~next then None
  else Some ()  (* Key is witness of non-fixpoint. *)


(* Find witnesses where next </= previous. *)
let non_fixpoint_witness ~iteration _kind left right =
  let open Result in
  match left, right with
  | None, None -> failwith "impossible"
  | None, Some (Pkg { kind = ModelPart kind; value = next; }) ->
      let empty = get_empty_model kind in
      non_fixpoint_witness kind ~iteration ~previous:empty ~next
  | Some (Pkg { kind = ModelPart kind; value = previous}), None ->
      let empty = get_empty_model kind in
      non_fixpoint_witness kind ~iteration ~previous ~next:empty
  | Some (Pkg { kind = ModelPart k1; value = previous; }),
    Some (Pkg { kind = ModelPart k2; value = next; }) ->
      match Kind.are_equal k1 k2 with
      | Kind.Equal -> non_fixpoint_witness k1 ~iteration ~previous ~next
      | Kind.Distinct -> failwith "Wrong kind matched up in fixpoint test."


let reached_fixpoint ~iteration ~previous ~next =
  Kind.Map.merge (non_fixpoint_witness ~iteration) previous next
  |> Kind.Map.is_empty


let join_models ~iteration left right =
  let open Result in
  let widen_pkg _
      (Pkg { kind = ModelPart left_kind; value = left; })
      (Pkg { kind = ModelPart right_kind; value = right; }) =
    match Kind.are_equal left_kind right_kind with
    | Kind.Equal ->
        let module Analysis = (val (Result.get_analysis left_kind)) in
        Some (Pkg { kind = ModelPart left_kind; value = Analysis.join ~iteration left right; })
    | Kind.Distinct ->
        failwith "Wrong kind matched up in widen."
  in
  if phys_equal left right then
    left
  else
    Kind.Map.union widen_pkg left right


let widen_models ~iteration ~previous ~next =
  let open Result in
  let widen_pkg _
      (Pkg { kind = ModelPart k1; value = previous; })
      (Pkg { kind = ModelPart k2; value = next; }) =
    match Kind.are_equal k1 k2 with
    | Kind.Equal ->
        let module Analysis = (val (Result.get_analysis k1)) in
        Some (Pkg { kind = ModelPart k1; value = Analysis.widen ~iteration ~previous ~next; })
    | Kind.Distinct ->
        failwith "Wrong kind matched up in widen."
  in
  if phys_equal previous next
  then previous
  else Kind.Map.union widen_pkg previous next


let explain_non_fixpoint ~iteration ~previous ~next =
  let open Result in
  let witnesses = Kind.Map.merge (non_fixpoint_witness ~iteration) previous next in
  let print_witness key () = Log.log ~section:`Interprocedural "%s is non-fixpoint" (Kind.show key)
  in
  Kind.Map.iter print_witness witnesses


let show_models models =
  let open Result in
  (* list them to make the type system do its work *)
  let to_string (akind, Pkg { kind = ModelPart kind; value = model; }) =
    let module Analysis = (val (get_analysis kind))
    in
    Format.sprintf "%s: %s" (Kind.show akind) (Analysis.show_call_model model)
  in
  Kind.Map.bindings models
  |> List.map ~f:to_string
  |> String.concat ~sep:"\n"


let widen ~iteration ~previous ~next =
  let verify_widen ~iteration ~previous ~next =
    let result = widen_models ~iteration ~previous ~next in
    if not (reached_fixpoint ~iteration ~previous:result ~next:previous) then
      begin
        Log.error "WIDEN DOES NOT RESPECT JOIN: previous = %s\nwiden = %s\n"
          (show_models previous) (show_models result);
        explain_non_fixpoint ~iteration ~previous:result ~next:previous
      end;
    if not (reached_fixpoint ~iteration ~previous:result ~next:next) then
      begin
        Log.error "WIDEN DOES NOT RESPECT JOIN: next = %s\nwiden = %s\n"
          (show_models next) (show_models result);
        explain_non_fixpoint ~iteration ~previous:result ~next:next
      end;
    result
  in
  if phys_equal previous next then
    previous
  else
    verify_widen ~iteration ~previous ~next


let widen_if_necessary step callable { Result.models = new_model; is_obscure } result =
  let callable = (callable :> Callable.t) in
  (* Check if we've reached a fixed point *)
  match Fixpoint.get_old_model callable with
  | None ->
      Format.asprintf "No initial model found for %a" Callable.pp callable
      |> failwith
  | Some old_model ->
      if reached_fixpoint ~iteration:step.Fixpoint.iteration
          ~previous:old_model.models ~next:new_model then begin
        Log.log
          ~section:`Interprocedural
          "Reached fixpoint for %a\n%a"
          Callable.pp callable
          Result.pp_model_t old_model;
        Fixpoint.{ is_partial = false; model = old_model; result }
      end
      else
        let model = Result.{
            models =
              widen
                ~iteration:step.Fixpoint.iteration
                ~previous:old_model.models
                ~next:new_model;
            is_obscure;
          }
        in
        Log.log
          ~section:`Interprocedural
          "Widened fixpoint for %a\nold: %anew: %a\nwidened: %a"
          Callable.pp callable
          Result.pp_model_t old_model
          Result.pp_model_t {models=new_model; is_obscure}
          Result.pp_model_t model;
        Fixpoint.{
          is_partial = true;
          model;
          result;
        }


let analyze_define
    step
    analyses
    callable
    environment
    ({ Node.value = { Define.name; _ }; _ } as define) =
  let () =
    Log.log
      ~section:`Interprocedural
      "Analyzing %a"
      Callable.pp_real_target callable
  in
  let new_model, results =
    let analyze (Result.Analysis { Result.kind; analysis; }) =
      let open Result in
      let akind = Kind.abstract kind in
      let module Analysis = (val analysis) in
      let method_result, method_model = Analysis.analyze ~callable ~environment ~define in
      (
        akind,
        Pkg { kind = ModelPart kind; value = method_model; },
        Pkg { kind = ResultPart kind; value = method_result; }
      )
    in
    let accumulate (models, results) analysis =
      let akind, model, result = analyze analysis
      in
      Result.Kind.Map.add akind model models,
      Result.Kind.Map.add akind result results
    in
    try
      (* Run all the analyses *)
      let init = Result.Kind.Map.(empty, empty) in
      let models, results = List.fold ~f:accumulate analyses ~init in
      models, results
    with
    | Analysis.TypeOrder.Untracked annotation ->
        Log.log
          ~section:`Info
          "Could not generate model for `%a` due to invalid annotation `%a`"
          Access.pp name
          Analysis.Type.pp annotation;
        Result.Kind.Map.empty, Result.Kind.Map.empty
    | Sys.Break as exn ->
        analysis_failed step ~exn ~message:"Hit Ctrl+C" callable
    | _ as exn ->
        analysis_failed step ~exn ~message:"Analysis failed" callable
  in
  widen_if_necessary step callable { Result.models=new_model; is_obscure=false } results


let analyze_overrides ({ Fixpoint.iteration; _ } as step) callable =
  let overrides =
    DependencyGraphSharedMemory.get_overriding_types ~member:(Callable.get_override_access callable)
    |> Option.value ~default:[]
    |> List.map ~f:(fun at_type -> Callable.create_derived_override callable ~at_type)
  in
  let model =
    let get_override_model override =
      match Fixpoint.get_model override with
      | None ->  (* inidicates this is the leaf and not explicitly represented *)
          Fixpoint.get_model (Callable.get_corresponding_method override)
      | model ->
          model
    in
    let lookup_and_join ({ Result.is_obscure; models } as result) override =
      match get_override_model override with
      | None ->
          result
      | Some model ->
          {
            is_obscure = is_obscure || model.is_obscure;
            models = join_models ~iteration models model.models;
          }
    in
    let direct_model =
      Fixpoint.get_model (Callable.get_corresponding_method callable)
      |> Option.value ~default:Result.empty_model
    in
    List.fold overrides ~f:lookup_and_join ~init:direct_model
  in
  widen_if_necessary step callable model Result.empty_result


let analyze_callable analyses step callable environment =
  let resolution = Analysis.TypeCheck.resolution environment () in
  let () = (* Verify invariants *)
    let open Fixpoint in
    match Fixpoint.get_meta_data callable with
    | None -> ()
    | Some { step = { epoch; _ }; _ } when epoch <> step.epoch ->
        let message =
          Format.sprintf "Fixpoint inconsistency: callable %s analyzed during epoch %s, but stored \
                          metadata from epoch %s"
            (Callable.show callable)
            (Fixpoint.Epoch.show step.epoch)
            (Fixpoint.Epoch.show epoch)
        in
        Log.error "%s" message;
        failwith message
    | _ -> ()
  in
  match callable with
  | #Callable.real_target as callable ->
      begin
        match Callable.get_definition callable ~resolution with
        | None ->
            let () =
              Log.error
                "Found no definition for %s"
                (Callable.show callable)
            in
            let () =
              if not (Fixpoint.is_initial_iteration step) then
                let message =
                  Format.sprintf "Fixpoint inconsistency: Callable %s without body analyzed past \
                                  initial step: %s"
                    (Callable.show callable)
                    (Fixpoint.show_step step)
                in
                Log.error "%s" message;
                failwith message
            in
            Fixpoint.{
              is_partial = false;
              model = get_obscure_models analyses;
              result = Result.empty_result;
            }
        | Some define ->
            analyze_define step analyses callable environment define
      end
  | #Callable.override_target as callable ->
      analyze_overrides step callable
  | #Callable.object_target as path ->
      Format.asprintf
        "Found object %a in fixpoint analysis"
        Callable.pp path
      |> failwith


let get_errors results =
  let open Result in
  let get_diagnostics (Pkg { kind = ResultPart kind; value; }) =
    let module Analysis = (val (get_analysis kind)) in
    Analysis.get_errors value
  in
  Kind.Map.bindings results
  |> List.map ~f:snd
  |> List.map ~f:get_diagnostics
  |> List.concat_no_order


let externalize_analysis kind callable models results =
  let open Result in
  let merge kind_candidate model_opt result_opt =
    if kind_candidate = kind then
      match model_opt, result_opt with
      | Some model, _ ->
          Some (model, result_opt)
      | None, Some (Pkg { kind = ResultPart kind; _ }) ->
          let module Analysis = (val (Result.get_analysis kind)) in
          let model = Pkg { kind = ModelPart kind; value = Analysis.empty_model} in
          Some (model, result_opt)
      | _ ->
          None
    else
      None
  in
  let merged = Kind.Map.merge merge models results in
  let get_summaries (_key, (Pkg { kind = ModelPart kind1; value = model; }, result_option)) =
    match result_option with
    | None ->
        let module Analysis = (val (Result.get_analysis kind1)) in
        Analysis.externalize callable None model
    | Some (Pkg { kind = ResultPart kind2; value = result; }) ->
        match Result.Kind.are_equal kind1 kind2 with
        | Kind.Equal ->
            let module Analysis = (val (Result.get_analysis kind1)) in
            Analysis.externalize callable (Some result) model
        | Kind.Distinct -> failwith "kind mismatch"
  in
  Kind.Map.bindings merged
  |> List.concat_map ~f:get_summaries


let externalize kind callable =
  match Fixpoint.get_model callable with
  | Some model ->
      let results = Fixpoint.get_result callable in
      externalize_analysis kind callable model.models results
  | None ->
      []


let emit_externalization kind emitter callable =
  externalize kind callable
  |> List.iter ~f:emitter


(* Called on a worker with a set of functions to analyze. *)
let one_analysis_pass ~analyses ~step ~environment ~callables =
  let analyses = List.map ~f:Result.get_abstract_analysis analyses in
  let analyze_and_cache callable =
    let result = analyze_callable analyses step callable environment in
    Fixpoint.add_state step callable result
  in
  List.iter callables ~f:analyze_and_cache;
  List.length callables


let get_callable_dependents ~dependencies callable =
  let explicit =
    Callable.Map.find dependencies callable
    |> Option.value ~default:[]
  in
  (* Add implicit dependencies *)
  let implicit =
    match callable with
    | #Callable.method_target as method_target ->
        (* Leafs have no explicit override target. So for these we need to
           expand to their explicit parents. *)
        let override_target = Callable.get_corresponding_override method_target in
        if Fixpoint.has_model override_target then
          [override_target]
        else
          Callable.Map.find dependencies override_target
          |> Option.value ~default:[]
    | _ ->
        []
  in
  implicit @ explicit


let compute_callables_to_reanalyze step previous_batch ~dependencies ~all_callables =
  let open Fixpoint in
  let reanalyze_caller caller accumulator =
    Callable.Set.add caller accumulator
  in
  let might_change_if_reanalyzed =
    List.fold previous_batch ~init:Callable.Set.empty
      ~f:(fun accumulator callable ->
          if not (Fixpoint.get_is_partial callable) then
            accumulator
          else
            (* c must be re-analyzed next iteration because its result has
               changed, and therefore its callers must also be reanalyzed. *)
            let callers = get_callable_dependents ~dependencies callable in
            List.fold callers ~init:(Callable.Set.add callable accumulator)
              ~f:(fun accumulator caller -> reanalyze_caller caller accumulator))
  in
  (* Filter the original list in order to preserve topological sort order. *)
  let callables_to_reanalyze =
    List.filter
      all_callables
      ~f:(fun callable -> Callable.Set.mem callable might_change_if_reanalyzed)
  in
  let () =
    if List.length callables_to_reanalyze <> Callable.Set.cardinal might_change_if_reanalyzed then
      let missing =
        Callable.Set.diff might_change_if_reanalyzed (Callable.Set.of_list callables_to_reanalyze)
      in
      let check_missing callable =
        match Fixpoint.get_meta_data callable with
        | None -> () (* okay, caller is in a later epoch *)
        | Some { step = { epoch; _ }; _ } when epoch = Epoch.predefined -> ()
        | Some meta ->
            let message =
              Format.sprintf
                "Re-analysis in iteration %d determined to analyze %s but it is not \
                 part of epoch %s (meta: %s)"
                step.iteration
                (Callable.show callable)
                (Fixpoint.Epoch.show step.epoch)
                (Fixpoint.meta_data_to_string meta)
            in
            Log.error "%s" message;
            failwith message
      in
      Callable.Set.iter check_missing missing
  in
  callables_to_reanalyze


let compute_fixpoint
    ~configuration
    ~scheduler
    ~environment
    ~analyses
    ~dependencies
    ~all_callables
    epoch =
  (* Start iteration > 0 is to avoid a useless special 0 iteration for mega
     components. *)
  let max_iterations = 100 in
  let rec iterate ~iteration callables_to_analyze =
    let number_of_callables = List.length callables_to_analyze in
    let () =
      let witnesses =
        if number_of_callables <= 6 then
          String.concat ~sep:", " (List.map ~f:Callable.show callables_to_analyze)
        else
          "..."
      in
      Log.log
        ~section:`Info
        "Iteration #%d. %d Callables [%s]"
        iteration
        number_of_callables
        witnesses
    in
    if number_of_callables = 0 then
      (* Fixpoint. *)
      iteration
    else if iteration >= max_iterations then
      begin
        let max_to_show = 15 in
        let bucket =
          callables_to_analyze
          |> List.map ~f:Callable.show
          |> List.sort ~compare:String.compare
        in
        let bucket_len = List.length bucket in
        let message =
          Format.sprintf
            "For a bucket of %d callables: %s%s"
            bucket_len
            (String.concat ~sep:", " (List.take bucket max_to_show))
            (if bucket_len > max_to_show then "..." else "")
        in
        Log.error "%s" message;
        failwith message
      end
    else
      let time_0 = Unix.gettimeofday () in
      let step = Fixpoint.{ epoch; iteration; } in
      let old_batch = Fixpoint.KeySet.of_list callables_to_analyze in
      let reduce n m =
        let callables_processed = n + m in
        let () =
          Log.log
            ~section:`Progress
            "Processed %d of %d callables"
            callables_processed
            number_of_callables
        in
        callables_processed
      in
      let () =
        Fixpoint.oldify old_batch;
        let _ =
          Scheduler.map_reduce
            scheduler
            ~configuration
            ~map:(fun _ callables -> one_analysis_pass ~analyses ~step ~environment ~callables)
            ~bucket_size:1000
            ~initial:0
            ~reduce
            ~inputs:callables_to_analyze
            ()
        in
        Fixpoint.remove_old old_batch
      in
      let callables_to_analyze =
        compute_callables_to_reanalyze step callables_to_analyze ~dependencies ~all_callables
      in
      let hs = SharedMem.heap_size () in
      let time_f = Unix.gettimeofday () in
      let elapsed = time_f -. time_0 |> Unix.gmtime in
      let () =
        Log.log ~section:`Info "Iteration #%n, %d callables, heap size %n took %nm %02ds"
          iteration number_of_callables hs elapsed.Unix.tm_min elapsed.Unix.tm_sec
      in
      iterate ~iteration:(iteration + 1) callables_to_analyze
  in
  try
    iterate ~iteration:0 all_callables
  with exn ->
    Log.error
      "Fixpoint iteration failed.\nException %s\nBacktrace: %s"
      (Exn.to_string exn)
      (Printexc.get_backtrace ());
    raise exn


let extract_errors scheduler ~configuration all_callables =
  let extract_errors callables =
    List.fold
      ~f:(fun errors callable -> (Fixpoint.get_result callable |> get_errors) :: errors)
      ~init:[]
      callables
    |> List.concat_no_order
  in
  Scheduler.map_reduce
    scheduler
    ~configuration
    ~initial:[]
    ~map:(fun _ callables -> extract_errors callables)
    ~reduce:List.cons
    ~inputs:all_callables
    ()
  |> List.concat_no_order


let save_results ~configuration ~analyses all_callables =
  let emit_json_array_elements out_buffer =
    let seen_element = ref false in
    fun json ->
      if !seen_element then
        begin
          Bi_outbuf.add_string out_buffer ",\n";
          Json.to_outbuf out_buffer json;
        end
      else
        begin
          seen_element := true;
          Json.to_outbuf out_buffer json;
        end
  in
  match configuration.Configuration.StaticAnalysis.result_json_path with
  | None -> ()
  | Some directory ->
      let save_models (Result.Analysis { Result.analysis; kind }) =
        let kind = Result.Kind.abstract kind in
        let module Analysis = (val analysis) in
        let filename = Format.sprintf "%s-output.json" Analysis.name in
        let output_path = Path.append directory ~element:filename in
        let out_channel = open_out (Path.absolute output_path) in
        let out_buffer = Bi_outbuf.create_channel_writer out_channel in
        let array_emitter = emit_json_array_elements out_buffer in
        let root =
          configuration.Configuration.StaticAnalysis.configuration.local_root
          |> Path.absolute
        in
        let config =
          `Assoc [
            "repo", `String root;
          ]
        in
        (* I wish Yojson had a stream emitter. *)
        Bi_outbuf.add_string out_buffer "{\n";
        Bi_outbuf.add_string out_buffer "\"config\": ";
        Json.to_outbuf out_buffer config;
        Bi_outbuf.add_string out_buffer ",\n";
        Bi_outbuf.add_string out_buffer "\"results\": [\n";
        List.iter ~f:(emit_externalization kind array_emitter) all_callables;
        Bi_outbuf.add_string out_buffer "\n]\n";
        Bi_outbuf.add_string out_buffer "}\n";
        Bi_outbuf.flush_output_writer out_buffer;
        close_out out_channel
      in
      let analyses = List.map ~f:Result.get_abstract_analysis analyses in
      let save_metadata (Result.Analysis { Result.analysis; _ }) =
        let module Analysis = (val analysis) in
        let filename = Format.sprintf "%s-metadata.json" Analysis.name in
        let output_path = Path.append directory ~element:filename in
        let out_channel = open_out (Path.absolute output_path) in
        let out_buffer = Bi_outbuf.create_channel_writer out_channel in
        Analysis.metadata ()
        |> Json.to_outbuf out_buffer;
        Bi_outbuf.flush_output_writer out_buffer;
        close_out out_channel
      in
      List.iter analyses ~f:save_models;
      List.iter analyses ~f:save_metadata

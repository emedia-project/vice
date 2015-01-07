-module(xrel_release).
-include("../include/xrel.hrl").

-export([
         make_root/1,
         resolv_apps/1,
         resolv_boot/2,
         make_lib/2,
         make_release/3,
         make_bin/1,
         include_erts/1,
         make_boot_script/1
        ]).

make_root(State) ->
  {outdir, Outdir} = xrel_config:get(State, outdir),
  case efile:make_dir(Outdir) of
    ok ->
      ?INFO("* Create directory ~s", [Outdir]);
    {error, Reason} ->
      ?HALT("!!! Failed to create ~s: ~p", [Outdir, Reason])
  end.

resolv_apps(State) ->
  {release, {_, _}, Apps} = xrel_config:get(State, release),
  Apps1 = case xrel_config:get(State, all_deps, false) of
    {all_deps, true} -> find_all_deps(State, Apps);
    _ -> Apps
  end,
  resolv_apps(State, Apps1, [], []).

resolv_boot(State, AllApps) ->
  case xrel_config:get(State, boot, all) of
    {boot, all} -> AllApps;
    {boot, Apps} -> resolv_apps(State, Apps, [], [])
  end.

make_lib(State, Apps) ->
  {outdir, Outdir} = xrel_config:get(State, outdir),
  LibDir = filename:join(Outdir, "lib"),
  Src = case xrel_config:get(State, include_src, false) of
          {include_src, true} -> ["src", "include"];
          {include_src, false} -> []
        end,
  case efile:make_dir(LibDir) of
    ok ->
      lists:foreach(fun(#{app := App, vsn := Vsn, path := Path}) ->
                        copy_deps(App, Vsn, Path, LibDir, Src)
                    end, Apps);
    {error, Reason} ->
      ?HALT("!!! Failed to create ~s: ~p", [LibDir, Reason])
  end.

make_release(State, AllApps, BootApps) ->
  {outdir, Outdir} = xrel_config:get(State, outdir),
  {relvsn, Vsn} = xrel_config:get(State, relvsn),
  RelDir = filename:join([Outdir, "releases", Vsn]),
  ?INFO("* Create ~s", [RelDir]),
  case efile:make_dir(RelDir) of 
    ok ->
      _ = make_rel_file(State, RelDir, "vm.args", vm_args),
      _ = make_rel_file(State, RelDir, "sys.config", sys_config),
      xrel_tempdir:mktmp(fun(TmpDir) ->
                             BootErl = make_rel_file(State, TmpDir, "extrel.erl", extrel),
                             BootExe = xrel_escript:build(BootErl, filename:dirname(BootErl)),
                             case efile:copyfile(BootExe, filename:join(RelDir, filename:basename(BootExe))) of
                               ok -> ok;
                               {error, Reason} ->
                                 ?HALT("Can't copy ~s: ~p", [BootExe, Reason])
                             end
                         end),
      _ = make_release_file(State, RelDir, AllApps, ".deps"),
      _ = make_release_file(State, RelDir, BootApps, ".rel");
    {error, Reason} ->
      ?HALT("!!! Failed to create ~s: ~p", [RelDir, Reason])
  end.

make_boot_script(State) ->
  {outdir, Outdir} = xrel_config:get(State, outdir),
  {relname, Relname} = xrel_config:get(State, relname),
  {relvsn, RelVsn} = xrel_config:get(State, relvsn),
  RelDir = filename:join("releases", RelVsn),
  ?INFO("* Create boot script", []),
  eos:in(Outdir, 
         fun() ->
             case systools:make_script(
                    eutils:to_list(Relname), 
                    [{path, 
                      [RelDir|filelib:wildcard("lib/*/ebin")]},
                     {outdir, RelDir},
                     silent]) of
               error -> 
                 ?HALT("!!! Can't generate boot script", []);
               {error, _, Error} ->
                 ?HALT("!!! Error while generating boot script : ~p", [Error]);
               {ok, _, []} ->
                 ok;
               {ok, _, Warnings} ->
                 ?DEBUG("! Generate boot script : ~p", [Warnings]);
               _ -> 
                 ok
             end
         end).

make_bin(State) ->
  {binfile, BinFile} = xrel_config:get(State, binfile),
  {relvsn, Vsn} = xrel_config:get(State, relvsn),
  {relname, Name} = xrel_config:get(State, relname),
  BinFileWithVsn = BinFile ++ "-" ++ Vsn,
  ?INFO("* Generate ~s", [BinFile]),
  _ = case efile:make_dir(filename:dirname(BinFile)) of
    ok -> ok;
    {error, Reason} ->
      ?HALT("!!! Failed to create ~s: ~p", [BinFile, Reason])
  end,
  case run_dtl:render([{relvsn, Vsn}, {relname, Name}, {ertsvsn, erlang:system_info(version)}]) of
    {ok, Data} ->
      case file:write_file(BinFile, Data) of
        ok -> 
          ?INFO("* Generate ~s", [BinFileWithVsn]),
          Bins = case file:copy(BinFile, BinFileWithVsn) of
            {ok, _} -> 
              [BinFile, BinFileWithVsn];
            {error, Reason2} ->
              ?ERROR("Error while creating ~s: ~p", [BinFileWithVsn, Reason2]),
              [BinFile]
          end,
          lists:foreach(fun(Bin) ->
                            case file:change_mode(Bin, 8#777) of
                              ok -> ok;
                              {error, Reason1} ->
                                ?HALT("!!! Can't set executable to ~s: ~p", [Bin, Reason1])
                            end
                        end, Bins);
        {error, Reason1} ->
          ?HALT("!!! Error while creating ~s: ~p", [BinFile, Reason1])
      end;
    {error, Reason1} ->
      ?HALT("!!! Error while creating ~s: ~p", [BinFile, Reason1])
  end.

include_erts(State) ->
  case case xrel_config:get(State, include_erts, true) of
         {include_erts, false} -> false;
         {include_erts, true} -> code:root_dir();
         {include_erts, X} when is_list(X) -> filename:absname(X);
         {include_erts, Y} ->
           ?HALT("!!! Invalid value for parameter include_erts: ~p", [Y])
       end of
    false ->
      ok;
    Path ->
      ?INFO("* Add ets ~s from ~s", [erlang:system_info(version), Path]),
      {outdir, Outdir} = xrel_config:get(State, outdir),
      efile:copy(
        filename:join(Path, "erts-" ++ erlang:system_info(version)), 
        Outdir,
        [recursive])
  end.

% Private

find_all_deps(State, Apps) ->
  {exclude_dirs, Exclude} = xrel_config:get(State, exclude_dirs),
  case efile:wildcard(
         filename:join(["**", "ebin", "*.app"]),
         Exclude
        ) of
    [] -> Apps;
    DepsApps -> 
      lists:foldl(fun(Path, Acc) ->
                      App = filename:basename(Path, ".app"),
                      case elists:include(Acc, App) of
                        true -> Acc;
                        false -> [eutils:to_atom(App)|Acc]
                      end
                  end, Apps, DepsApps)
  end.

resolv_apps(_, [], _, Apps) -> Apps;
resolv_apps(State, [App|Rest], Done, AllApps) ->
  {App, Vsn, Path, Deps} = case resolv_app(State, filename:join("**", "ebin"), App) of
                             notfound -> 
                               case resolv_app(State, filename:join([code:root_dir(), "lib", "**"]), App) of
                                 notfound ->
                                   ?HALT("!!! Can't find application ~s", [App]);
                                 R -> R
                               end;
                             R -> R
                           end,
  Done1 = [App|Done],
  Rest1 = elists:delete_if(fun(A) ->
                               elists:include(Done1, A)
                           end, lists:umerge(lists:sort(Rest), lists:sort(Deps))),
  resolv_apps(
    State,
    Rest1,
    Done1,
    [#{app => App, vsn => Vsn, path => Path}| AllApps]).

resolv_app(State, Path, Name) ->
  {exclude_dirs, Exclude} = xrel_config:get(State, exclude_dirs),
  case efile:wildcard(
         filename:join(Path, eutils:to_list(Name) ++ ".app"),
         Exclude
        ) of
    [] -> notfound;
    [AppFile|_] -> 
      AppPathFile = efile:expand_path(AppFile),
      case file:consult(AppPathFile) of
        {ok, [{application, Name, Config}]} ->
          Vsn = case lists:keyfind(vsn, 1, Config) of
                  {vsn, Vsn1} -> Vsn1;
                  _ -> "0"
                end,
          Deps = case lists:keyfind(applications, 1, Config) of
                   {applications, Apps} -> Apps;
                   _ -> []
                 end,
          {Name, Vsn, app_path(Name, Vsn, AppPathFile), Deps};
        E -> 
          ?HALT("!!! Invalid ~p.app file ~s: ~p", [Name, AppPathFile, E])
      end
  end.

app_path(App, Vsn, Path) ->
  Dirname = filename:dirname(Path),
  AppName = eutils:to_list(App) ++ "-" ++ Vsn,
  case string:str(Dirname, AppName) of
    0 ->
      case string:str(Dirname, eutils:to_list(App)) of
        0 ->
          ?HALT("!!! Can't find root path for ~s", [App]);
        N ->
          string:substr(Dirname, 1, N + length(eutils:to_list(App)))
      end;
    N -> 
      string:substr(Dirname, 1, N + length(AppName))
  end.

copy_deps(App, Vsn, Path, Dest, Extra) ->
  ?INFO("* Copy ~s version ~s", [App, Vsn]),
  efile:copy(Path, Dest, [recursive, {only, ["ebin", "priv"] ++ Extra}]),
  FinalDest = filename:join(Dest, eutils:to_list(App) ++ "-" ++ Vsn),
  CopyDest = filename:join(Dest, filename:basename(Path)),
  if
    FinalDest =:= CopyDest -> ok;
    true ->
      _ = case filelib:is_dir(FinalDest) of
            true ->
              case efile:remove_recursive(FinalDest) of
                ok -> ok;
                {error, Reason} ->
                  ?HALT("!!! Can't remove ~s: ~p", [FinalDest, Reason])
              end;
            false ->
              ok
          end,
      case file:rename(CopyDest, FinalDest) of
        ok -> 
          ?INFO("* Move ~s to ~s", [CopyDest, FinalDest]);
        {error, Reason1} ->
          ?HALT("!!! Can't rename ~s: ~p", [CopyDest, Reason1])
      end
  end.

make_rel_file(State, RelDir, File, Type) ->
  Dest = filename:join(RelDir, File),
  ?INFO("* Create ~s", [Dest]),
  case xrel_config:get(State, Type, false) of
    {Type, false} ->
      Mod = eutils:to_atom(eutils:to_list(Type) ++ "_dtl"),
      {relname, RelName} = xrel_config:get(State, relname),
      case Mod:render([{relname, RelName}]) of
        {ok, Data} ->
          case file:write_file(Dest, Data) of
            ok -> Dest;
            {error, Reason1} ->
              ?HALT("!!! Error while creating ~s: ~p", [Dest, Reason1])
          end;
        {error, Reason} ->
          ?HALT("!!! Error while creating ~s: ~p", [Dest, Reason])
      end;
    {Type, Src} ->
      case file:copy(Src, Dest) of
        {ok, _} -> Dest;
        {error, Reason} ->
          ?HALT("!!! Can't copy ~s to ~s: ~p", [Src, Dest, Reason])
      end
  end.

make_release_file(State, RelDir, Apps, Ext) ->
  {relname, Name} = xrel_config:get(State, relname),
  {relvsn, Vsn} = xrel_config:get(State, relvsn),
  Params = [
            {relname, Name},
            {relvsn, Vsn},
            {ertsvsn, erlang:system_info(version)},
            {apps, lists:map(fun maps:to_list/1, Apps)}
           ],
  Dest = filename:join(RelDir, eutils:to_list(Name) ++ Ext),
  ?INFO("* Create ~s", [Dest]),
  case rel_dtl:render(Params) of
    {ok, Data} ->
      case file:write_file(Dest, Data) of
        ok -> ok;
        {error, Reason1} ->
          ?HALT("!!! Error while creating ~s: ~p", [Dest, Reason1])
      end;
    {error, Reason} ->
      ?HALT("!!! Error while creating ~s: ~p", [Dest, Reason])
  end.


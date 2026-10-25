%% SPDX-License-Identifier: Apache-2.0
%% Private package CLI policy. Build uses explicitly selected host capabilities.
-module(beam_pkg).
-export([command/2, operate/2]).

command(Context={beam_context,1,_,_,_,_,Root,_,_,_,Bytes}, Arguments) ->
    Services=case Arguments of
        ["build"|_] -> [output,file,program,zlib];
        ["install"|_] -> [output,file,program,zlib];
        ["export"|_] -> [output,file,program,zlib];
        ["task"|_] -> [output,file];
        [Operation,"--project",Directory|Rest] when Operation =:= "run"; Operation =:= "shell" ->
            case {Directory,Operation,Rest} of
                {[],_,_} -> [];
                {[$-|_],_,_} -> [];
                {_,"run",[]} -> [output,file];
                {_,"run",["--"|_]} -> [output,file];
                {_,"shell",[]} -> [output,file];
                _ -> []
            end;
        _ -> []
    end,
    case Services of
        [] -> operate(Context,Arguments);
        _ ->
            D0=binary_to_term(Bytes),
            D1=setelement(8,setelement(6,setelement(5,D0,Root),{command,<<"beam_pkg">>,<<"operate">>}),Services),
            {beam_command,1,{run,D1,term_to_binary(Arguments)}}
    end.

operate({beam_context,1,_,Prefix,Identity,Build,_,Cwd,Search,<<"posix">>,_}, Arguments) ->
    put(command_name, <<"beam-pkg">>),
    Context = {Identity,Prefix,Cwd,Search},
    try dispatch([utf8(A) || A <- Arguments], Context, Build)
    catch
        throw:{package_error,Message} -> report({standard_error,1,["beam-pkg: ",Message,"\n"]});
        Class:Reason:Stack -> report({standard_error,1,["beam-pkg: package operation failed: ",beam_pkg_util:text({Class,Reason,Stack}),"\n"]})
    end.

utf8(A) when is_list(A) -> << <<C/utf8>> || C <- A >>.

dispatch([Operation|Rest], Context, _) when Operation=:=<<"build">>; Operation=:=<<"install">> ->
    A=beam_pkg_target:arguments(Rest,false),
    Selection=beam_pkg_target:select(Context,map_get(target,A)),
    Dir=map_get(directory,A),
    case Operation of
        <<"build">> -> {ok,Archive}=beam_pkg_build:run(Dir,Context,Selection),
            report({standard_output,0,["Built ",Archive,"\nUpdated beam.lock\n"]});
        <<"install">> -> {ok,Environment}=beam_pkg_environment:install(Dir,Context,Selection),
            report({standard_output,0,["Installed ",Environment,"\n"]})
    end;
dispatch([<<"export">>|Rest],Context,_) ->
    A=beam_pkg_target:arguments(Rest,true),
    S=beam_pkg_target:select(Context,map_get(target,A)),
    {ok,Output}=beam_pkg_export:run(map_get(directory,A),map_get(output,A),Context,S),
    report({standard_output,0,["Exported ",Output,"\n"]});
dispatch([<<"task">>|Rest],Context,_) ->
    case beam_pkg_task:prepare({Context,Rest}) of
        {list,Text} -> report({standard_output,0,Text});
        {exec,{Directory,Argv}} -> {beam_command,1,{exec,Directory,task_command(Context,Argv)}};
        {error,Message} -> beam_pkg_util:fail(Message)
    end;
dispatch([Purpose|Rest],Context,Build) when Purpose =:= <<"run">>; Purpose =:= <<"shell">> ->
    Kind = case Purpose of <<"run">> -> run; _ -> shell end,
    {Directory,Args} = project_arguments(Rest,Kind),
    case beam_pkg_environment:prepare({Context,Directory,host_modules(Context,Kind),Kind}) of
        {ok,{Entry,Modules,Native}} ->
            {_,_,Cwd,_}=Context,
            Root=beam_pkg_util:path(Cwd,Directory),
            Contract=case Kind of run -> main; shell -> shell end,
            Inventory=[{memory,Name,Bytes,Origin} || {Name,Bytes,Origin} <- Modules],
            Bindings=[{Name,relative(Root,Path)} || {Name,Path} <- Native],
            D={beam_application,1,<<"project">>,<<"2">>,Root,
               {Contract,Entry,<<"main">>},[application_v1,native_v1],[output],
               Inventory,Bindings,[Build],[]},
            {beam_command,1,{run,D,term_to_binary([unicode_list(A) || A <- Args])}};
        {error,Message} -> beam_pkg_util:fail(Message)
    end;
dispatch(Arguments,{Identity,_,_,_},_) -> report(information(Arguments,Identity)).

project_arguments([<<"--project">>,Directory|Rest],Kind) when Directory =/= <<>> ->
    case Directory of <<"-",_/binary>> -> beam_pkg_util:fail("invalid project arguments"); _ -> ok end,
    case {Kind,Rest} of
        {shell,[]} -> {Directory,[]};
        {run,[]} -> {Directory,[]};
        {run,[<<"--">>|Args]} -> {Directory,Args};
        _ -> beam_pkg_util:fail("invalid project arguments")
    end;
project_arguments(_,_) -> beam_pkg_util:fail("invalid project arguments").

task_command({_,Prefix,_,_},[Name|Rest]) when Name=:=<<"beam">>; Name=:=<<"beam-pkg">> ->
    [beam_pkg_util:path(Prefix,<<"bin/",Name/binary>>)|Rest];
task_command(_,Argv) -> Argv.

unicode_list(B) -> [C || <<C/utf8>> <= B].
relative(Root,Path) ->
    Prefix = <<Root/binary,"/">>, N=byte_size(Prefix),
    case Path of <<Prefix:N/binary,Rest/binary>> -> Rest;
        _ -> beam_pkg_util:fail("native output outside project") end.

host_modules({_,Prefix,_,_},Kind) ->
    Extra=case Kind of shell -> [<<"runtime/beam/interactive">>]; run -> [] end,
    Paths=[<<"library">>,<<"boot">>,<<"services">>,<<"runtime/beam/cli">>|Extra],
    Core=[atom_to_binary(M,utf8) || M <- erlang:pre_loaded()],
    Core ++ [<<"beam_application_run">>] ++
        append([ [M || M <- beam_pkg_util:split(beam_pkg_util:read(
            beam_pkg_util:path(Prefix,<<"lib/beam/",P/binary,"/modules.txt">>)),10),M=/=<<>>] || P <- Paths]).
append([]) -> [];
append([H|T]) -> H ++ append(T).

report({Destination,Status,Text}) ->
    Code=case beam_output:write(Destination,iolist_to_binary(Text),infinity) of ok -> Status; _ -> 1 end,
    {beam_command,1,{exit,Code}}.

information([], _) -> help([]);
information([<<"help">> | Rest], _) -> help(Rest);
information([<<"version">>], Identity) ->
    {standard_output, 0, [Identity, <<"\nbeam-pkg: experimental local packages; tree is not implemented\n">>]};
information([Operation | Rest], _)
  when Operation =:= <<"tree">> ->
    case directory(Rest) of
        {ok, _Directory} ->
            {standard_error, 2, [<<"beam-pkg: ">>, Operation, <<": not implemented (experimental scaffold)\n">>]};
        error -> invalid()
    end;
information(_, _) -> invalid().

directory([]) -> {ok, <<".">>};
directory([<<>>]) -> error;
directory([<<"-", _/binary>>]) -> error;
directory([Path]) -> {ok, Path};
directory(_) -> error.

help([]) -> {standard_output, 0, usage()};
help([Name]) ->
    case syntax(Name) of
        error -> invalid();
        Text -> {standard_output, 0, [<<"usage: ">>, Text, <<"\n">>, status()]}
    end;
help(_) -> invalid().

syntax(<<"help">>) -> <<"beam-pkg help [command]">>;
syntax(<<"version">>) -> <<"beam-pkg version">>;
syntax(<<"build">>) -> <<(get(command_name))/binary, " build [--target-sdk SDK] [directory]">>;
syntax(<<"install">>) -> <<"beam-pkg install [--target-sdk SDK] [project]">>;
syntax(<<"export">>) -> <<"beam-pkg export [--target-sdk SDK] --output directory [project]">>;
syntax(<<"run">>) -> <<"beam-pkg run --project <directory> [-- args...]">>;
syntax(<<"shell">>) -> <<"beam-pkg shell --project <directory>">>;
syntax(<<"task">>) -> <<"beam-pkg task [--project <directory>] [name [-- args...]]">>;
syntax(<<"tree">>) -> <<"beam-pkg tree [project]">>;
syntax(_) -> error.

invalid() -> {standard_error, 1, [get(command_name), <<": invalid arguments\n">>, usage()]}.
usage() ->
    case get(command_name) of
        <<"beam">> -> <<"usage: beam build [--target-sdk SDK] [directory]\n">>;
        _ -> package_usage()
    end.
package_usage() ->
    [<<"usage: beam-pkg <command> [args]\n"
       "  help [command]       Show syntax and status\n"
       "  version              Show distribution identity and status\n"
       "  build [--target-sdk SDK] [directory]    Build local Erlang/native packages\n"
       "  install [project]    Install the locked project\n"
       "  export --output dir  Export installed application inputs\n"
       "  tree [project]       Show dependencies (not implemented)\n"
       "Directories default to .; use ./ for names beginning with -.\n">>, status()].
status() -> <<"Experimental local packages and BEAM project execution.\n">>.

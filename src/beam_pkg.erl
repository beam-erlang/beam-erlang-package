%% SPDX-License-Identifier: Apache-2.0
%% Private package CLI policy. Build uses explicitly selected host capabilities.
-module(beam_pkg).
-export([main/1, beam_main/1]).

main(Arguments) -> main_for(<<"beam-pkg">>, Arguments).
beam_main(Arguments) -> main_for(<<"beam">>, Arguments).
main_for(Name, {Context={Identity,_,_,_}, Arguments}) ->
    put(command_name, Name),
    {Destination, Status, Text} = try
        case Arguments of
            [<<"install">> | Rest] ->
                case directory(Rest) of
                    {ok, Dir} -> {ok, Environment}=beam_pkg_environment:install(Dir, Context),
                                 {standard_output,0,["Installed ",Environment,"\n"]};
                    error -> invalid()
                end;
            [<<"build">> | Rest] ->
                case directory(Rest) of
                    {ok, Dir} -> {ok, Archive}=beam_pkg_build:run(Dir,Context),
                                 {standard_output,0,["Built ",Archive,"\nUpdated beam.lock\n"]};
                    error -> invalid()
                end;
            _ -> command(Arguments, Identity)
        end
    catch
        throw:{package_error,Message} -> {standard_error,1,[Name, ": ",Message,"\n"]};
        Class:Reason:Stack -> {standard_error,1,[Name, ": package operation failed: ",beam_pkg_util:text({Class,Reason,Stack}),"\n"]}
    end,
    case beam_output:write(Destination, iolist_to_binary(Text), infinity) of
        ok -> beam_boot:finish(Status);
        {error, _} -> beam_boot:finish(1)
    end.

command([], _) -> help([]);
command([<<"help">> | Rest], _) -> help(Rest);
command([<<"version">>], Identity) ->
    {standard_output, 0, [Identity, <<"\nbeam-pkg: experimental local packages; tree is not implemented\n">>]};
command([Operation | Rest], _)
  when Operation =:= <<"tree">> ->
    case directory(Rest) of
        {ok, _Directory} ->
            {standard_error, 2, [<<"beam-pkg: ">>, Operation, <<": not implemented (experimental scaffold)\n">>]};
        error -> invalid()
    end;
command(_, _) -> invalid().

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
syntax(<<"build">>) -> <<(get(command_name))/binary, " build [directory]">>;
syntax(<<"install">>) -> <<"beam-pkg install [project]">>;
syntax(<<"tree">>) -> <<"beam-pkg tree [project]">>;
syntax(_) -> error.

invalid() -> {standard_error, 1, [get(command_name), <<": invalid arguments\n">>, usage()]}.
usage() ->
    case get(command_name) of
        <<"beam">> -> <<"usage: beam build [directory]\n">>;
        _ -> package_usage()
    end.
package_usage() ->
    [<<"usage: beam-pkg <command> [args]\n"
       "  help [command]       Show syntax and status\n"
       "  version              Show distribution identity and status\n"
       "  build [directory]    Build local Erlang/native packages\n"
       "  install [project]    Install the locked project\n"
       "  tree [project]       Show dependencies (not implemented)\n"
       "Directories default to .; use ./ for names beginning with -.\n">>, status()].
status() -> <<"Experimental local packages and BEAM project execution.\n">>.

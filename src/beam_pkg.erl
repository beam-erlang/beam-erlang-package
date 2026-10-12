%% SPDX-License-Identifier: Apache-2.0
%% Private package CLI policy. No project or package files are accessed.
-module(beam_pkg).
-export([main/1]).

main({Identity, Arguments}) ->
    {Destination, Status, Text} = command(Arguments, Identity),
    case beam_output:write(Destination, iolist_to_binary(Text), infinity) of
        ok -> beam_boot:finish(Status);
        {error, _} -> beam_boot:finish(1)
    end.

command([], _) -> help([]);
command([<<"help">> | Rest], _) -> help(Rest);
command([<<"version">>], Identity) ->
    {standard_output, 0, [Identity, <<"\nbeam-pkg: experimental scaffold; package operations are not implemented\n">>]};
command([Operation | Rest], _)
  when Operation =:= <<"build">>; Operation =:= <<"install">>; Operation =:= <<"tree">> ->
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
syntax(<<"build">>) -> <<"beam-pkg build [directory]">>;
syntax(<<"install">>) -> <<"beam-pkg install [project]">>;
syntax(<<"tree">>) -> <<"beam-pkg tree [project]">>;
syntax(_) -> error.

invalid() -> {standard_error, 1, [<<"beam-pkg: invalid arguments\n">>, usage()]}.
usage() ->
    [<<"usage: beam-pkg <command> [args]\n"
       "  help [command]       Show syntax and status\n"
       "  version              Show distribution identity and status\n"
       "  build [directory]    Build packages (not implemented)\n"
       "  install [project]    Install a project (not implemented)\n"
       "  tree [project]       Show dependencies (not implemented)\n"
       "Directories default to .; use ./ for names beginning with -.\n">>, status()].
status() -> <<"Experimental scaffold: no manifests are read and no package operations are performed.\n">>.

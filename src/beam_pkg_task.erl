%% SPDX-License-Identifier: Apache-2.0
%% Development tasks are source policy, never portable package metadata.
-module(beam_pkg_task).
-export([prepare/1, scripts/1]).
-import(beam_pkg_util, [get/3, fail/1, path/2, read/1, keys/1, sort/1]).

prepare({{_, _, Cwd, _}, Args}) ->
    try command(Cwd, Args)
    catch
        throw:{package_error, Message} -> {error, Message};
        Class:Reason -> {error, iolist_to_binary(["invalid task: ", beam_pkg_util:text({Class, Reason})])}
    end.

command(_, [<<"--help">>]) ->
    {list, <<"usage: beam task [--project <directory>] [name [-- arguments...]]\nLiteral argv tasks from the root beam.toml; no implicit build or install.\n">>};
command(Cwd, [<<"--project">>, Directory | Rest]) ->
    nonempty(Directory), select(path(Cwd, Directory), Rest);
command(Cwd, Args) -> select(Cwd, Args).

select(Root, Args) ->
    {Name, Extra} = arguments(Args),
    File = path(Root, <<"beam.toml">>),
    case beam_pkg_util:info(File) of
        {ok, #{type := regular, size := Size}} when Size =< 1048576 -> ok;
        _ -> fail("missing or oversized task manifest")
    end,
    M = beam_pkg_toml:decode(read(File)),
    case get(<<"format">>, M, undefined) of 1 -> ok; _ -> fail("unsupported package format") end,
    beam_pkg_manifest:identity(M),
    Tasks = scripts(get(<<"scripts">>, M, #{})),
    case Name of
        undefined ->
            Names = sort(keys(Tasks)),
            {list, case Names of [] -> <<"No development tasks defined.\n">>;
                _ -> iolist_to_binary([[N, "\n"] || N <- Names]) end};
        _ ->
            Command = case get(Name, Tasks, undefined) of
                undefined -> fail(["unknown task: ", Name]); V -> V end,
            Argv = argv(Command ++ Extra),
            {exec, {Root, Argv}}
    end.

arguments([]) -> {undefined, []};
arguments([<<"-", _/binary>> | _]) -> fail("invalid task arguments; see beam help task");
arguments([Name]) -> nonempty(Name), {Name, []};
arguments([Name, <<"--">> | Extra]) -> nonempty(Name), {Name, Extra};
arguments(_) -> fail("task arguments must follow --").

scripts(M) when is_map(M), map_size(M) =< 1024 ->
    [begin nonempty(Name), argv(Command) end || Name := Command <- M], M;
scripts(_) -> fail("scripts must be a table of literal argument arrays").
argv([Executable | _] = Args) when length(Args) =< 1024 ->
    nonempty(Executable),
    [argument(A) || A <- Args],
    case size_sum(Args) =< 1048576 of true -> Args; false -> fail("task arguments exceed size limit") end;
argv(_) -> fail("task needs a nonempty argument array").
size_sum([]) -> 0;
size_sum([H | T]) -> byte_size(H) + size_sum(T).
nonempty(<<>>) -> fail("empty task name, directory or executable");
nonempty(B) -> argument(B).
argument(B) when is_binary(B), byte_size(B) =< 16384 ->
    case [C || <<C>> <= B, C =:= 0] of [] -> ok; _ -> fail("NUL in task argument") end,
    utf8(B), B;
argument(_) -> fail("task arguments must be bounded strings").

utf8(<<>>) -> ok;
utf8(<<_/utf8, Rest/binary>>) -> utf8(Rest);
utf8(_) -> fail("invalid UTF-8 task argument").

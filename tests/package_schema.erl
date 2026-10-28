%% SPDX-License-Identifier: Apache-2.0
%% Focused format checks, run by builds.py with newly compiled package modules.
-module(package_schema).
-export([main/1]).

main([]) ->
    formats(), native(), graphs(), toml_limits(), archive_limits(),
    io:format("Package schema and serialization boundaries passed~n").

sdk() ->
    #{<<"format">> => 1, <<"identity">> => <<"fixture">>,
      <<"build-id">> => repeat(<<"0">>,64), <<"os">> => <<"Linux">>,
      <<"architecture">> => <<"x86_64">>, <<"triple">> => <<"x86_64-linux">>,
      <<"flavor">> => <<"emu">>}.
metadata() ->
    #{<<"format">> => 1, <<"package">> => #{<<"name">> => <<"test/schema">>, <<"version">> => <<"exact-version">>},
      <<"modules">> => [<<"probe">>, <<"other">>], <<"compiler">> => sdk(),
      <<"compiler-generation">> => repeat(<<"1">>,64)}.
valid(M) -> M = beam_pkg_manifest:metadata(M), ok.
bad(M, Text) -> rejected(fun() -> valid(M) end, Text).
formats() ->
    M = metadata(), valid(M),
    [bad(M#{<<"format">> := V}, <<"unsupported package format">>) || V <- [0,2,3]],
    bad(without(<<"compiler-generation">>,M), <<"provenance; rebuild">>),
    S = #{<<"format">> => 1, <<"package">> => map_get(<<"package">>,M)},
    S = beam_pkg_manifest:source(S),
    Outputs = #{<<"cmake">> => <<".">>, <<"outputs">> => [<<"probe">>,<<"probe">>]},
    rejected(fun() -> beam_pkg_manifest:source(S#{<<"build">> => #{<<"native">> => Outputs}}) end,
             <<"duplicate native source outputs">>).

artifact(Name, Dependencies) ->
    P = <<"priv/",Name/binary,".so">>,
    #{<<"path">> => P, <<"files">> => [P], <<"kind">> => <<"shared">>,
      <<"dependencies">> => Dependencies, <<"language">> => <<"C">>,
      <<"sdk-build-id">> => map_get(<<"build-id">>,sdk())}.
native_meta(Artifacts) ->
    #{<<"sdk">> => sdk(), <<"recipe">> => <<"cmake">>, <<"artifacts">> => Artifacts}.
with_native(N) -> (metadata())#{<<"native">> => N}.
native() ->
    R = artifact(<<"probe">>,[]), P = map_get(<<"path">>,R),
    A = #{<<"probe">> => R}, N = native_meta(A),
    valid(with_native(N)),
    Bound = N#{<<"nifs">> => #{<<"probe">> => P}},
    valid(with_native(Bound)),
    [bad(with_native(N#{K => V}), <<"obsolete native metadata">>) ||
        {K,V} <- [{<<"outputs">>,[P]},{<<"identities">>,#{<<"probe">>=>P}}]],
    bad(with_native(N#{<<"artifacts">> := A#{<<"other">> => R}}), <<"duplicate native artifact files">>),
    bad_artifact(N,R#{<<"files">> := [P,P]}, <<"duplicate native artifact files">>),
    bad_artifact(N,R#{<<"files">> := [<<"priv/aux.h">>]}, <<"missing primary inventory">>),
    bad_artifact(N,R#{<<"sdk-build-id">> := repeat(<<"2">>,64)}, <<"SDK/target mismatch">>),
    bad_artifact(N,R#{<<"dependencies">> := [<<"output:missing">>]}, <<"unresolved native dependency">>),
    bad_artifact(N,R#{<<"dependencies">> := [<<"system:m">>,<<"system:m">>]}, <<"duplicate native dependencies">>),
    Auxiliary = Bound#{<<"artifacts">> := #{<<"probe">> => R#{<<"files">> := [P,<<"priv/aux.h">>]}}},
    bad(with_native(Auxiliary#{<<"nifs">> := #{<<"probe">> => <<"priv/aux.h">>}}), <<"does not match">>),
    bad(with_native(Bound#{<<"nifs">> := #{<<"missing">> => P}}), <<"supplied module">>),
    bad(with_native(Bound#{<<"nifs">> := #{<<"probe">> => P, <<"other">> => P}}), <<"multiple module bindings">>),
    Static = R#{<<"kind">> := <<"static">>, <<"files">> := [P,<<"priv/registration.h">>],
                <<"module">> => <<"probe">>, <<"binding">> => <<"probe_registration">>,
                <<"header">> => <<"priv/registration.h">>},
    valid(with_native(N#{<<"artifacts">> := #{<<"probe">> => Static}})),
    valid(with_native(Bound#{<<"artifacts">> := #{<<"probe">> => Static}})),
    bad_artifact(Bound,Static#{<<"module">> := <<"other">>}, <<"does not match">>),
    bad_artifact(N,without(<<"binding">>,Static), <<"incomplete linked-NIF">>),
    bad_artifact(N,without(<<"header">>,Static), <<"invalid linked-NIF inventory">>).
bad_artifact(N,R,Text) -> bad(with_native(N#{<<"artifacts">> := #{<<"probe">> => R}}),Text).

name(I) -> <<"node",(integer_to_binary(I))/binary>>.
edge(I) -> <<"output:",(name(I))/binary>>.
chain(Count) -> #{name(I) => artifact(name(I),case I of Count -> []; _ -> [edge(I+1)] end)
                   || I <- seq(Count)}.
graphs() ->
    valid(with_native(native_meta(chain(128)))),
    bad(with_native(native_meta(chain(129))), <<"depth limit">>),
    Cycle = #{<<"a">> => artifact(<<"a">>,[<<"output:b">>]),
              <<"b">> => artifact(<<"b">>,[<<"output:a">>])},
    bad(with_native(native_meta(Cycle)), <<"cycle">>),
    Self = #{<<"a">> => artifact(<<"a">>,[<<"output:a">>])},
    bad(with_native(native_meta(Self)), <<"unresolved native dependency">>),
    %% A compact layered DAG has exponentially many paths but few nodes/edges.
    DAG = #{name(I) => artifact(name(I),[edge(J) || J <- [I+1,I+2], J =< 60]) || I <- seq(60)},
    valid(with_native(native_meta(DAG))),
    %% Visit the shared suffix first and last: neither ordering may hide depth.
    [begin
        A = chain(128),
        Root = artifact(RootName,[edge(128),edge(1)]),
        bad(with_native(native_meta(A#{RootName => Root})), <<"depth limit">>)
     end || RootName <- [<<"aaa">>,<<"zzz">>]].

toml_limits() ->
    Limit = 4194304,
    Overhead = byte_size(beam_pkg_toml:encode(#{<<"v">> => <<>>})),
    Bytes = repeat(<<"x">>,Limit-Overhead),
    Record = #{<<"v">> => Bytes},
    Encoded = beam_pkg_toml:encode(Record), Limit = byte_size(Encoded),
    Record = beam_pkg_toml:decode(Encoded),
    rejected(fun() -> beam_pkg_toml:encode(#{<<"v">> => <<Bytes/binary,"x">>}) end, <<"4 MiB">>),
    rejected(fun() -> beam_pkg_toml:decode(<<Encoded/binary," ">>) end, <<"4 MiB">>),
    %% Encoding limits apply after escaping, not just to the input string bytes.
    Escaped = repeat(<<10>>, (Limit-Overhead) div 2),
    _ = beam_pkg_toml:encode(#{<<"v">> => Escaped}),
    rejected(fun() -> beam_pkg_toml:encode(#{<<"v">> => <<Escaped/binary,10>>}) end, <<"4 MiB">>).

archive_limits() ->
    Files = #{integer_to_binary(I) => <<>> || I <- seq(10000)},
    Packed = beam_pkg_archive:pack(Files),
    Files = beam_pkg_archive:unpack(Packed),
    rejected(fun() -> beam_pkg_archive:pack(Files#{<<"extra">> => <<>>}) end, <<"entry limit">>),
    %% The expanded limit includes tar headers, padding and the terminator.
    Limit = 268435456,
    Payload = <<0:((Limit-1536)*8)>>,
    Large = beam_pkg_archive:pack(#{<<"large">> => Payload}),
    #{<<"large">> := Payload} = beam_pkg_archive:unpack(Large),
    rejected(fun() -> beam_pkg_archive:pack(#{<<"large">> => <<Payload/binary,0>>}) end, <<"size limit">>),
    rejected(fun() -> beam_pkg_archive:unpack(<<0:((Limit+1)*8)>>) end, <<"compressed archive exceeds limit">>).

rejected(Fun, Text) ->
    try Fun(), erlang:error({expected_rejection,Text})
    catch throw:{package_error,Message} ->
        case contains(iolist_to_binary(Message),Text) of
            true -> ok; false -> erlang:error({wrong_diagnostic,Text,Message})
        end
    end.
contains(B, Part) ->
    Size = byte_size(Part),
    case B of
        <<Part:Size/binary,_/binary>> -> true;
        <<_,Rest/binary>> -> contains(Rest,Part);
        <<>> -> false
    end.
without(Key, Map) -> #{K => V || K := V <- Map, K =/= Key}.
seq(0) -> [];
seq(N) -> [N | seq(N-1)].
repeat(_,0) -> <<>>;
repeat(B,N) ->
    Half = repeat(B,N div 2),
    Tail = case N rem 2 of 0 -> <<>>; 1 -> B end,
    <<Half/binary,Half/binary,Tail/binary>>.

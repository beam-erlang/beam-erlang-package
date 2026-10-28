%% SPDX-License-Identifier: Apache-2.0
%% Host execution and target linkage are separate, verified selections.
-module(beam_pkg_target).
-export([select/2, compatible/2, arguments/2, verify_native/3]).
-import(beam_pkg_util,[path/2,read/1,get/3,fail/1]).

select(Context={_,Host,Cwd,_},Selected) ->
    Target=case Selected of undefined -> Host; _ -> path(Cwd,Selected) end,
    CMake=beam_pkg_util:tool(<<"cmake">>,Context),
    verify(CMake,Host,true), verify(CMake,Target,false),
    HostSDK=sdk(Host), SDK=sdk(Target),
    H=facts(Host), T=facts(Target),
    Generation=get(<<"compiler-generation">>,H,undefined),
    beam_pkg_manifest:digest(Generation),
    case Generation =:= get(<<"compiler-generation">>,T,undefined) of
        true -> ok; false -> fail("host and target compiler generations differ") end,
    #{sdk=>SDK,host_sdk=>HostSDK,prefix=>Host,target_prefix=>Target,
      target=>T,host_target=>H,generation=>Generation,cmake=>CMake,cross=>SDK=/=HostSDK}.
verify(C,P,Compiler) ->
    _=beam_pkg_util:command(C,
        [case Compiler of true -> <<"-DBEAM_VERIFY_COMPILER=ON">>; false -> <<"-DBEAM_VERIFY_COMPILER=OFF">> end,
         <<"-P">>,path(P,<<"lib/cmake/BEAM/support/BEAMVerifySDK.cmake">>)],P),ok.
sdk(P) ->
    S=beam_pkg_toml:decode(read(path(P,<<"lib/beam/sdk.toml">>))),
    _=beam_pkg_manifest:target_key(S),S.
facts(P) -> beam_pkg_toml:decode(read(path(P,<<"lib/beam/target.toml">>))).
compatible(M,S) ->
    case get(<<"compiler-generation">>,M,undefined)=:=map_get(generation,S) of
        true -> ok; false -> fail("archive compiler generation mismatch; rebuild package")
    end,
    case get(<<"native">>,M,undefined) of
        undefined -> ok;
        N ->
            case get(<<"sdk">>,N,undefined)=:=map_get(sdk,S) of
                true -> ok; false -> fail("native archive SDK/target mismatch") end,
            Allowed=map_get(<<"native-kinds">>,map_get(target,S)),
            [case beam_pkg_util:member(map_get(<<"kind">>,R),Allowed) of
                true -> ok; false -> fail("native artifact kind is unsupported by target SDK") end
             || _:=R<-get(<<"artifacts">>,N,#{})]
    end.

arguments(Args,Export) -> arguments(Args,Export,#{target=>undefined,directory=><<".">>},false).
arguments([],true,#{output:=_}=M,_) -> M;
arguments([],true,_,_) -> fail("export requires --output <directory>");
arguments([],false,M,_) -> M;
arguments([<<"--target-sdk">>,P|Rest],E,#{target:=undefined}=M,D) when P=/=<<>> ->
    arguments(Rest,E,M#{target:=P},D);
arguments([<<"--output">>,P|Rest],true,M,D) when P=/=<<>> ->
    case is_map_key(output,M) of true -> fail("duplicate --output"); false -> arguments(Rest,true,M#{output=>P},D) end;
arguments([<<"-",_/binary>>|_],_,_,_) -> fail("invalid arguments");
arguments([P|Rest],E,M,false) when P=/=<<>> -> arguments(Rest,E,M#{directory:=P},true);
arguments(_,_,_,_) -> fail("invalid arguments").


%% Inspection uses the selected NDK host tool; target code is never executed.
verify_native([],_,_) -> ok;
verify_native(Files,Stage,S) ->
    case map_get(<<"system">>,map_get(target,S)) of
        <<"Android">> ->
            Input=path(Stage,<<"android-native-check.cmake">>),
            ABI=map_get(<<"android-abi">>,map_get(target,S)),
            beam_pkg_util:write(Input,iolist_to_binary([
                "set(BEAM_ANDROID_ABI ",cmake_quote(ABI),")\n",
                "set(BEAM_ANDROID_NATIVE_FILES\n",[[cmake_quote(P),"\n"] || P<-Files],")\n"])),
            try
                _=beam_pkg_util:command(map_get(cmake,S),
                    [<<"-DBEAM_ANDROID_NATIVE_INPUTS=",Input/binary>>,<<"-P">>,
                     path(map_get(target_prefix,S),<<"lib/cmake/BEAM/support/BEAMVerifyAndroidNative.cmake">>)],Stage),ok
            after beam_pkg_util:remove(Input) end;
        _ -> ok
    end.
cmake_quote(B) -> iolist_to_binary([$",[case C of $\\ -> "\\\\"; $" -> "\\\""; $$ -> "\\$"; $; -> "\\;"; _ -> C end || <<C>> <= B],$"]).

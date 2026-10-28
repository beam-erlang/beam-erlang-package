%% SPDX-License-Identifier: Apache-2.0
%% Export an already installed selection. Never build or resolve source graphs.
-module(beam_pkg_export).
-export([run/4]).
-import(beam_pkg_util,[path/2,read/1,mkdir/1,get/3,keys/1,sort/1,fail/1]).

run(Directory,Output,Context={_,_,Cwd,_},S) ->
    {Root,Nodes}=beam_pkg_environment:export_selection(Context,Directory,S),
    Destination=path(Cwd,Output),
    Marker=path(Destination,<<".beam-package-export">>),
    case beam_pkg_util:info(Destination) of
        {error,#{kind:=not_found}} -> mkdir(Destination),write(Marker,<<"1\n">>);
        {ok,#{type:=directory}} -> case read(Marker) of <<"1\n">> -> ok; _ -> fail("not a package export directory") end;
        _ -> fail("invalid package export destination")
    end,
    Generations=path(Destination,<<".generations">>),mkdir(Generations),
    Id=integer_to_binary(erlang:unique_integer([positive,monotonic])),
    Unique = <<(integer_to_binary(erlang:system_time(nanosecond)))/binary,"-",Id/binary>>,
    Stage=path(Generations,<<"stage-",Unique/binary>>),
    Final=path(Generations,Unique),
    Pending=path(Destination,<<"current-",Unique/binary>>),
    mkdir(Stage),
    C=map_get(cmake,S),
    try
        [beam_pkg_target:compatible(map_get(meta,N),S) || _:=N<-Nodes],
        Records=copy_nodes(sort(keys(Nodes)),Nodes,Stage,C,#{}),
        NativePaths=append([[path(Stage,<<"packages/",H/binary,"/",(map_get(<<"path">>,A))/binary>>) ||
            _:=A<-get(<<"artifacts">>,map_get(native_meta,N),#{})] || H:=N<-Nodes]),
        beam_pkg_target:verify_native(NativePaths,Stage,S),
        {Registrations,Shared,Native,CMakeLinks,XcodeLinks}=native(Nodes),
        Registration=iolist_to_binary([
            "/* Generated package linked NIF selections. */\n#include <beam/beam.h>\n",
            [["extern const beam_linked_nif_spec *",Symbol,"(void);\n"] || Symbol<-Registrations]]),
        Count=integer_to_binary(length(Registrations)),
        write(path(Stage,<<"registration.c">>),[Registration,shared_registration(Shared),
            "size_t beam_package_linked_nifs(beam_linked_nif_spec *out, size_t capacity) {\n",
            case Registrations of
                [] -> " (void)out; (void)capacity;\n";
                _ -> [" if (!out || capacity < ",Count,") return ",Count,";\n"] end,
            [ [" out[",integer_to_binary(I),"] = *",Symbol,"();\n"] || {I,Symbol}<-indexed(Registrations,0)],
            " return ",Count,";\n}\n"]),
        write(path(Stage,<<"registration.h">>),
            <<"#include <beam/beam.h>\n#ifdef __cplusplus\nextern \"C\" {\n#endif\nsize_t beam_package_linked_nifs(beam_linked_nif_spec *, size_t);\nextern const size_t beam_package_shared_nif_count;\nextern const char *const beam_package_shared_nif_modules[];\nextern const char *const beam_package_shared_nif_libraries[];\n#ifdef __cplusplus\n}\n#endif\n">>),
        SDK=map_get(sdk,S),
        Inventory=#{<<"format">>=>1,<<"sdk">>=>SDK,<<"compiler-generation">>=>map_get(generation,S),
            <<"root">>=>Root,<<"packages">>=>Records},
        write(path(Stage,<<"export.toml">>),beam_pkg_toml:encode(Inventory)),
        write(path(Stage,<<"package_inventory.h">>),inventory_header()),
        write(path(Stage,<<"package_inventory.c">>),inventory_source(Records,Nodes,map_get(<<"build-id">>,SDK))),
        write(path(Stage,<<"package.cmake">>),[
            "# Generated relocatable package inputs.\nset(_beam_export_root \"${CMAKE_CURRENT_LIST_DIR}\")\n",
            "if(NOT BEAM_SDK_BUILD_ID STREQUAL \"",map_get(<<"build-id">>,SDK),"\")\nmessage(FATAL_ERROR \"Package export SDK mismatch\")\nendif()\n",
            "beam_check_native_target()\n",
            verification(Records),asset_variables(Records),
            "add_library(BEAMPackageInputs INTERFACE)\n",
            "target_sources(BEAMPackageInputs INTERFACE \"${_beam_export_root}/registration.c\" \"${_beam_export_root}/package_inventory.c\")\n",
            "target_include_directories(BEAMPackageInputs INTERFACE \"${_beam_export_root}\")\n",
            Native,"target_link_libraries(BEAMPackageInputs INTERFACE ",CMakeLinks,")\n",
            "set(BEAM_PACKAGE_NATIVE_TARGETS ",CMakeLinks,")\n",
            "set(BEAM_PACKAGE_EXPORT_ROOT \"${_beam_export_root}\")\n"]),
        Apple=beam_pkg_util:member(map_get(<<"system">>,map_get(target,S)),[<<"Darwin">>,<<"iOS">>]),
        case Apple of true -> write(path(Stage,<<"package.xcconfig">>),[
            "// BEAM_PACKAGE_EXPORT is supplied by the application build.\n",
            "BEAM_PACKAGE_SDK_BUILD_ID = ",map_get(<<"build-id">>,SDK),"\n",
            "OTHER_LDFLAGS = $(inherited) ",XcodeLinks,"\n"]); false -> ok end,
        rename(Stage,Final),
        %% Stable wrappers only refer to the single atomic selection pointer.
        Windows=case erlang:system_info(os_type) of {win32,_}->true;_->false end,
        Wrapper=case Windows of
            true -> <<"include(\"${CMAKE_CURRENT_LIST_DIR}/current.cmake\")\ninclude(\"${_beam_selected_export}/package.cmake\")\n">>;
            false -> <<"file(REAL_PATH \"${CMAKE_CURRENT_LIST_DIR}/current\" _beam_selected_export)\ninclude(\"${_beam_selected_export}/package.cmake\")\n">>
        end,
        write_once(path(Destination,<<"BEAMPackageExport.cmake">>),Wrapper),
        case Apple of
            true -> write_once(path(Destination,<<"BEAMPackageExport.xcconfig">>),<<"#include \"current/package.xcconfig\"\n">>);
            false -> ok
        end,
        case Windows of
            true ->
                %% A regular selector preserves atomic publication without
                %% requiring Windows symbolic-link privileges.
                write(Pending,["set(_beam_selected_export \"${CMAKE_CURRENT_LIST_DIR}/.generations/",Unique,"\")\n"]),
                rename(Pending,path(Destination,<<"current.cmake">>));
            false ->
                _=beam_pkg_util:command(C,[<<"-E">>,<<"create_symlink">>,<<".generations/",Unique/binary>>,Pending],Destination),
                rename(Pending,path(Destination,<<"current">>))
        end,
        {ok,Destination}
    catch
        Class:Reason:Stack -> cleanup(Final),erlang:raise(Class,Reason,Stack)
    after
        cleanup(Stage),cleanup(Pending)
    end.

copy_nodes([],_,_,_,A) -> A;
copy_nodes([H|T],Nodes,Stage,C,A) ->
    N=map_get(H,Nodes), M=map_get(meta,N),
    Files=map_get(files,N),
    MetadataInput=path(Stage,<<"metadata-input.toml">>),write(MetadataInput,map_get(<<"package.toml">>,Files)),
    case beam_pkg_util:hash(MetadataInput,C)=:=map_get(<<"package.toml">>,map_get(expected_files,N)) of
        true -> cleanup(MetadataInput); false -> fail("installed metadata integrity failure") end,
    Prefix = <<"packages/",H/binary>>,
    Inventory=#{P=>begin
        portable_path(P),Out=path(Stage,<<Prefix/binary,"/",P/binary>>),write(Out,B),
        Hash=beam_pkg_util:hash(Out,C),
        case Hash=:=map_get(P,map_get(expected_files,N)) of
            true -> Hash; false -> fail("installed artifact integrity failure; reinstall packages") end
        end || P:=B<-Files,P=/=<<"package.toml">>},
    R=#{<<"metadata">>=>M,<<"path">>=>Prefix,<<"files">>=>Inventory},
    copy_nodes(T,Nodes,Stage,C,A#{H=>R}).

native(Nodes) ->
    Items=append([begin
        N=map_get(native_meta,map_get(H,Nodes)),
        [{{H,Name},R,get(<<"nifs">>,N,#{})} || Name<-sort(keys(get(<<"artifacts">>,N,#{}))),R<-[map_get(Name,map_get(<<"artifacts">>,N))]]
    end || H<-sort(keys(Nodes))]),
    Names=#{Key=><<"beam_package_input_",(integer_to_binary(I))/binary>> || {I,{Key,_,_}}<-indexed(Items,0)},
    Registrations=[map_get(<<"binding">>,R) || {_,R,Nifs}<-Items,
        map_get(<<"kind">>,R)=:=<<"static">>,
        get(get(<<"module">>,R,undefined),Nifs,undefined)=:=map_get(<<"path">>,R)],
    CMake=[begin
        Target=map_get(Key,Names),P=relative_native(H,R),
        Kind=case map_get(<<"kind">>,R) of <<"static">> -> "STATIC"; _ -> "SHARED" end,
        Dependencies=[link(D,H,Names,cmake) || D<-map_get(<<"dependencies">>,R)],
        Language=map_get(<<"language">>,R),
        ["add_library(",Target," ",Kind," IMPORTED)\nset_target_properties(",Target,
         " PROPERTIES IMPORTED_LOCATION ",cq(["${_beam_export_root}/",P]),")\n",
         case Language of <<"CXX">> -> "enable_language(CXX)\n"; _ -> [] end,
         "set_property(TARGET ",Target," PROPERTY IMPORTED_LINK_INTERFACE_LANGUAGES ",Language,")\n",
         "set_property(TARGET ",Target," PROPERTY INTERFACE_LINK_LIBRARIES ",join(Dependencies," "),")\n"]
    end || {Key={H,_},R,_}<-Items],
    Xcode=[[xq(["$(BEAM_PACKAGE_EXPORT)/current/",relative_native(H,R)])," ",
        join([link(D,H,Names,xcode) || D<-map_get(<<"dependencies">>,R)]," "),
        case map_get(<<"language">>,R) of <<"CXX">> -> " -lc++"; _ -> [] end," "] || {{H,_},R,_}<-Items],
    Shared=[{Module,native_basename(P,P)} || {_,R,Nifs}<-Items,
        map_get(<<"kind">>,R)=:=<<"shared">>,Module<-sort(keys(Nifs)),
        P<-[map_get(Module,Nifs)],P=:=map_get(<<"path">>,R)],
    {Registrations,Shared,CMake,join([map_get(Key,Names) || {Key,_,_}<-Items]," "),Xcode}.
native_basename(<<>>,Name) -> Name;
native_basename(<<$/,Rest/binary>>,_) -> native_basename(Rest,Rest);
native_basename(<<_,Rest/binary>>,Name) -> native_basename(Rest,Name).
shared_registration(Shared) ->
    ["const size_t beam_package_shared_nif_count = ",integer_to_binary(length(Shared)),";\n",
     "const char *const beam_package_shared_nif_modules[] = {",
     case Shared of [] -> "0"; _ -> join([["\"",M,"\""] || {M,_}<-Shared],",") end,"};\n",
     "const char *const beam_package_shared_nif_libraries[] = {",
     case Shared of [] -> "0"; _ -> join([["\"",P,"\""] || {_,P}<-Shared],",") end,"};\n"].
relative_native(H,R) -> <<"packages/",H/binary,"/",(map_get(<<"path">>,R))/binary>>.
link(<<"sdk:runtime">>,_,_,cmake) -> "BEAM::Runtime";
link(<<"sdk:runtime">>,_,_,xcode) -> "-framework BEAM";
link(<<"system:",Name/binary>>,_,_,cmake) -> Name;
link(<<"system:",Name/binary>>,_,_,xcode) -> ["-l",Name];
link(<<"output:",Name/binary>>,H,Names,cmake) -> map_get({H,Name},Names);
link(<<"output:",_/binary>>,_,_,xcode) -> "".
verification(Records) -> [begin
    Prefix=map_get(<<"path">>,R),
    [["file(SHA256 ",cq(["${_beam_export_root}/",Prefix,"/",P])," _beam_hash)\n",
      "if(NOT _beam_hash STREQUAL \"",Hash,"\")\nmessage(FATAL_ERROR \"Package export integrity failure\")\nendif()\n"]
       || P:=Hash<-map_get(<<"files">>,R)]
    end || _:=R<-Records].
%% Only the generator's own variable references are interpolated.
cq(Parts) -> [$",escape(iolist_to_binary(Parts)),$"].
xq(Parts) -> cq(Parts).
escape(B) -> [case C of $" -> "\\\""; $\\ -> "\\\\"; $; -> "\\;"; 10 -> "\\n"; _ -> C end || <<C>><=B].
join(L,S) -> beam_pkg_util:join([iolist_to_binary(X) || X<-L],S).
append([]) -> []; append([H|T]) -> H++append(T).
indexed([],_) -> []; indexed([H|T],I) -> [{I,H}|indexed(T,I+1)].
rename(A,B) -> case beam_file:rename(A,B,infinity) of ok -> ok; E -> fail(["export publication failed: ",beam_pkg_util:text(E)]) end.
write_once(P,B) -> case beam_pkg_util:info(P) of
    {error,#{kind:=not_found}} -> write(P,B);
    {ok,#{type:=regular}} -> case read(P)=:=iolist_to_binary(B) of true->ok;false->fail("modified export wrapper") end;
    _ -> fail("invalid export wrapper") end.
cleanup(P) -> try beam_pkg_util:remove(P) catch _:_ -> ok end.

inventory_header() ->
    "/* Generated package bytecode expectations. */\n#ifndef BEAM_PACKAGE_INVENTORY_H\n#define BEAM_PACKAGE_INVENTORY_H\n#include <beam/sdk/bytecode.h>\n#ifdef __cplusplus\nextern \"C\" {\n#endif\nextern const beam_bytecode_inventory beam_package_inventory;\n#ifdef __cplusplus\n}\n#endif\n#endif\n".

inventory_source(Records,Nodes,Build) ->
    Modules=append([begin
        M=map_get(<<"metadata">>,R),Prefix=map_get(<<"path">>,R),Files=map_get(<<"files">>,R),
        [{Name,<<Prefix/binary,"/ebin/",Name/binary,".beam">>,map_get(<<"ebin/",Name/binary,".beam">>,Files),byte_size(map_get(<<"ebin/",Name/binary,".beam">>,map_get(files,map_get(H,Nodes))))} || Name<-map_get(<<"modules">>,M)]
    end || H:=R<-Records]),
    ["#include \"package_inventory.h\"\nstatic const beam_bytecode_record beam_package_records[] = {\n",
     case Modules of [] -> "{0},\n"; _ -> [] end,
     [["{\"",Name,"\",\"",P,"\",",integer_to_binary(Size),",{",digest_bytes(Hash),"}},\n"] || {Name,P,Hash,Size}<-Modules],
     "};\nconst beam_bytecode_inventory beam_package_inventory = {\"",Build,"\",",
     integer_to_binary(length(Modules)),",beam_package_records};\n"].
digest_bytes(<<>>) -> [];
digest_bytes(<<A,B,R/binary>>) -> ["0x",A,B,",",digest_bytes(R)].
asset_variables(Records) ->
    Assets=append([begin
        Prefix=map_get(<<"path">>,R),M=map_get(<<"metadata">>,R),
        E=get(<<"exports">>,M,#{}),
        [<<Prefix/binary,"/",P/binary>> || P<-
            [<<"ebin/",N/binary,".beam">> || N<-map_get(<<"modules">>,M)] ++
            get(<<"resources">>,E,[]) ++ get(<<"licenses">>,E,[])]
    end || _:=R<-Records]),
    ["set(BEAM_PACKAGE_ASSETS\n",[[cq(P),"\n"] || P<-Assets],")\n"].

portable_path(P) ->
    case [C || <<C>><=P,C=:=$$ orelse C=:=$" orelse C=:=$; orelse C=:=$` orelse C<32] of
        [] -> ok; _ -> fail("artifact path is not portable to CMake/Xcode exports") end.

write(P,B) -> beam_pkg_util:write(P,iolist_to_binary(B)).

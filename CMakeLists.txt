cmake_minimum_required(VERSION 3.25)
project(beam_erlang_package LANGUAGES NONE)
find_package(BEAM CONFIG REQUIRED)

include(cmake/PackageTool.cmake)
set(_payload "${CMAKE_CURRENT_BINARY_DIR}/payload/lib/beam/tools/pkg")
beam_package_build(beam_package_tool
    OUTPUT_DIRECTORY "${_payload}"
    COMPILER_COMMAND $<TARGET_FILE:BEAM::CLI> --runtime=beam compile --deterministic
    COMPILER_DEPENDS BEAM::CLI)
add_custom_target(package_tool ALL)
add_dependencies(package_tool beam_package_tool)
get_target_property(_files beam_package_tool BEAM_PACKAGE_FILES)
get_target_property(_inventory beam_package_tool BEAM_PACKAGE_INVENTORY)
install(FILES ${_files} DESTINATION lib/beam/tools/pkg/ebin)
install(FILES "${_inventory}" DESTINATION lib/beam/tools/pkg)

include(CTest)
if(BUILD_TESTING)
    find_package(Python3 3.9 REQUIRED COMPONENTS Interpreter)
    add_test(NAME package-commands
        COMMAND ${Python3_EXECUTABLE} -B "${CMAKE_CURRENT_SOURCE_DIR}/tests/commands.py"
            --beam $<TARGET_FILE:BEAM::CLI>
            --runtime $<TARGET_FILE:BEAM::Runtime>
            --boot "${BEAM_BOOT_COMPONENT}"
            --payload "${_payload}"
            --work "${CMAKE_CURRENT_BINARY_DIR}/checks")
    set_tests_properties(package-commands PROPERTIES TIMEOUT 180)
endif()

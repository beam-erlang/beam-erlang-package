cmake_minimum_required(VERSION 3.25)
project(beam_erlang_package LANGUAGES NONE)
find_package(BEAM CONFIG REQUIRED COMPONENTS CLI)
find_package(Python3 3.11 REQUIRED COMPONENTS Interpreter)

include(cmake/PackageTool.cmake)
set(_payload "${CMAKE_CURRENT_BINARY_DIR}/payload/lib/beam/apps/beam-pkg")
beam_package_build(beam_package_tool
    OUTPUT_DIRECTORY "${_payload}"
    COMPILER_COMMAND $<TARGET_FILE:BEAM::CLI> compile --deterministic
    COMPILER_DEPENDS BEAM::CLI
    DESCRIPTOR_TOOL "${BEAM_APPLICATION_TOOL}"
    RUNTIME_BUILD_ID "${BEAM_SDK_BUILD_ID}")
add_custom_target(package_tool ALL)
add_dependencies(package_tool beam_package_tool)
beam_package_install(beam_package_tool "${BEAM_APPLICATION_LAUNCHER}" absolute "$<TARGET_FILE:BEAM::CLI>")

include(CTest)
if(BUILD_TESTING)
    find_package(Python3 3.11 REQUIRED COMPONENTS Interpreter)
    add_test(NAME package-commands
        COMMAND ${Python3_EXECUTABLE} -B "${CMAKE_CURRENT_SOURCE_DIR}/tests/commands.py"
            --beam $<TARGET_FILE:BEAM::CLI>
            --payload "${_payload}"
            --work "${CMAKE_CURRENT_BINARY_DIR}/checks")
    set_tests_properties(package-commands PROPERTIES TIMEOUT 180)
endif()

if(BUILD_TESTING)
    add_test(NAME package-builds
        COMMAND ${Python3_EXECUTABLE} -B "${CMAKE_CURRENT_SOURCE_DIR}/tests/builds.py"
            --beam $<TARGET_FILE:BEAM::CLI> --payload "${_payload}"
            --work "${CMAKE_CURRENT_BINARY_DIR}/build-checks")
    set_tests_properties(package-builds PROPERTIES TIMEOUT 600)
endif()

if(BUILD_TESTING)
    add_test(NAME package-projects
        COMMAND ${Python3_EXECUTABLE} -B "${CMAKE_CURRENT_SOURCE_DIR}/tests/projects.py"
            --beam $<TARGET_FILE:BEAM::CLI> --payload "${_payload}"
            --work "${CMAKE_CURRENT_BINARY_DIR}/project-checks")
    set_tests_properties(package-projects PROPERTIES TIMEOUT 600)
endif()

if(BUILD_TESTING)
    add_test(NAME package-tasks
        COMMAND ${Python3_EXECUTABLE} -B "${CMAKE_CURRENT_SOURCE_DIR}/tests/tasks.py"
            --beam $<TARGET_FILE:BEAM::CLI> --payload "${_payload}"
            --work "${CMAKE_CURRENT_BINARY_DIR}/task-checks")
    set_tests_properties(package-tasks PROPERTIES TIMEOUT 300)
endif()

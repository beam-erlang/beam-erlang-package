cmake_minimum_required(VERSION 3.25)
project(beam_erlang_package LANGUAGES NONE)
find_package(BEAM CONFIG REQUIRED COMPONENTS CLI)
find_package(Python3 3.11 REQUIRED COMPONENTS Interpreter)

include(cmake/PackageTool.cmake)
option(BEAM_PACKAGE_ACQUIRED_PAYLOAD "Test the selected SDK's installed package payload without rebuilding it" OFF)
if(BEAM_PACKAGE_ACQUIRED_PAYLOAD)
    get_filename_component(_sdk_root "${BEAM_SDK_METADATA}/../../.." ABSOLUTE)
    set(_payload "${_sdk_root}/lib/beam/apps/beam-pkg")
    execute_process(COMMAND "${Python3_EXECUTABLE}" -B "${BEAM_APPLICATION_TOOL}"
        validate "${_payload}/application.etf" COMMAND_ERROR_IS_FATAL ANY)
    beam_package_modules(_expected_modules)
    file(STRINGS "${_payload}/modules.txt" _installed_modules)
    if(NOT _expected_modules STREQUAL _installed_modules)
        message(FATAL_ERROR "Installed package payload differs from selected source inventory")
    endif()
    file(SHA256 "${CMAKE_CURRENT_SOURCE_DIR}/cmake/BEAMPackageNative.cmake" _expected_helper)
    file(SHA256 "${_payload}/cmake/BEAMPackageNative.cmake" _installed_helper)
    if(NOT _expected_helper STREQUAL _installed_helper)
        message(FATAL_ERROR "Installed package native helper differs from selected source")
    endif()
else()
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
endif()

set(BEAM_PACKAGE_OPPOSITE_LIBC_SDK "" CACHE PATH "Explicit real Linux SDK for cross-libc rejection acceptance")
set(_opposite_sdk_args)
if(BEAM_PACKAGE_OPPOSITE_LIBC_SDK)
    list(APPEND _opposite_sdk_args --opposite-libc-sdk "${BEAM_PACKAGE_OPPOSITE_LIBC_SDK}")
endif()

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
            --work "${CMAKE_CURRENT_BINARY_DIR}/build-checks" ${_opposite_sdk_args})
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

set(BEAM_PACKAGE_IOS_DEVICE_SDK "" CACHE PATH "Explicit installed iOS device SDK for cross-target acceptance")
set(BEAM_PACKAGE_IOS_SIMULATOR_SDK "" CACHE PATH "Explicit installed iOS simulator SDK for cross-target acceptance")
set(BEAM_PACKAGE_FIRST_TARGET_SDK "${BEAM_PACKAGE_IOS_DEVICE_SDK}" CACHE PATH "First explicitly installed cross-target SDK")
set(BEAM_PACKAGE_SECOND_TARGET_SDK "${BEAM_PACKAGE_IOS_SIMULATOR_SDK}" CACHE PATH "Second explicitly installed cross-target SDK")
if(BUILD_TESTING AND BEAM_PACKAGE_FIRST_TARGET_SDK AND BEAM_PACKAGE_SECOND_TARGET_SDK)
    add_test(NAME package-cross-target
        COMMAND ${Python3_EXECUTABLE} -B "${CMAKE_CURRENT_SOURCE_DIR}/tests/cross.py"
            --beam $<TARGET_FILE:BEAM::CLI> --payload "${_payload}"
            --first-sdk "${BEAM_PACKAGE_FIRST_TARGET_SDK}"
            --second-sdk "${BEAM_PACKAGE_SECOND_TARGET_SDK}"
            --work "${CMAKE_CURRENT_BINARY_DIR}/cross-checks")
    set_tests_properties(package-cross-target PROPERTIES TIMEOUT 600)
endif()

if(BUILD_TESTING AND WIN32)
    add_test(NAME package-process-ownership
        COMMAND ${Python3_EXECUTABLE} -B "${CMAKE_CURRENT_SOURCE_DIR}/tests/test_process.py")
    set_tests_properties(package-process-ownership PROPERTIES TIMEOUT 30)
    set_tests_properties(package-commands package-builds package-projects package-tasks
        PROPERTIES ENVIRONMENT "PYTHONUTF8=1;PYTHONIOENCODING=utf-8")
endif()

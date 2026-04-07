cmake_minimum_required(VERSION 3.16)
project(validate_install CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(projectagamemnon REQUIRED)
find_package(projectnestor REQUIRED)
find_package(projectkeystone REQUIRED)

add_executable(validate_install main.cpp)

target_link_libraries(validate_install
    PRIVATE
        projectagamemnon::projectagamemnon
        projectnestor::projectnestor
        projectkeystone::projectkeystone
)

cmake_minimum_required(VERSION 3.20)
project(MyWinUI3App)

# 设置 C++ 标准
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 设置输出目录
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)

# 查找 Windows SDK
find_package(WindowsSDK REQUIRED)

# 查找 C++/WinRT
find_package(cppwinrt REQUIRED)

# 查找 WinUI 3
find_package(WinUI3 REQUIRED)

# 包含目录
include_directories(${CMAKE_CURRENT_SOURCE_DIR}/src)
include_directories(${WINDOWS_SDK_INCLUDE_DIRS})
include_directories(${CPPWINRT_INCLUDE_DIRS})
include_directories(${WINUI3_INCLUDE_DIRS})

# 源文件
set(SOURCES
    src/main.cpp
    src/App.cpp
    src/MainWindow.cpp
    src/MainWindow.xaml.cpp
)

# 头文件
set(HEADERS
    src/App.h
    src/MainWindow.h
    src/MainWindow.xaml.h
)

# XAML 文件
set(XAML_FILES
    src/MainWindow.xaml
    src/App.xaml
)

# 资源文件
set(RESOURCE_FILES
    src/App.rc
    src/App.manifest
)

# 创建可执行文件
add_executable(${PROJECT_NAME} 
    ${SOURCES} 
    ${HEADERS} 
    ${XAML_FILES} 
    ${RESOURCE_FILES}
)

# 链接库
target_link_libraries(${PROJECT_NAME}
    ${WINDOWS_SDK_LIBRARIES}
    ${CPPWINRT_LIBRARIES}
    ${WINUI3_LIBRARIES}
    windowsapp
    user32
    kernel32
    ole32
    oleaut32
    uuid
    comctl32
    shell32
    advapi32
    wininet
    ws2_32
    crypt32
    bcrypt
)

# 编译选项
target_compile_options(${PROJECT_NAME} PRIVATE
    /W4
    /WX
    /permissive-
    /std:c++20
    /utf-8
    /MP
    /O2
    /Ob2
    /Oi
    /Ot
    /Oy
    /GL
    /Gy
    /GS-
    /guard:cf
    /EHsc
)

# 链接选项
target_link_options(${PROJECT_NAME} PRIVATE
    /LTCG
    /OPT:REF
    /OPT:ICF
    /GUARD:CF
    /SUBSYSTEM:WINDOWS
    /ENTRY:mainCRTStartup
)

# 预处理器定义
target_compile_definitions(${PROJECT_NAME} PRIVATE
    WIN32
    _WINDOWS
    UNICODE
    _UNICODE
    WINRT_LEAN_AND_MEAN
    WINRT_IMPL
    NOMINMAX
    WIN32_LEAN_AND_MEAN
    VC_EXTRALEAN
    _CRT_SECURE_NO_WARNINGS
    _SILENCE_ALL_CXX17_DEPRECATION_WARNINGS
)

# 设置目标属性
set_target_properties(${PROJECT_NAME} PROPERTIES
    WIN32_EXECUTABLE TRUE
    VS_DEBUGGER_WORKING_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
)

# 复制资源文件
add_custom_command(TARGET ${PROJECT_NAME} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_directory
    ${CMAKE_SOURCE_DIR}/assets
    ${CMAKE_BINARY_DIR}/bin/assets
    COMMENT "Copying assets"
)

# 安装规则
install(TARGETS ${PROJECT_NAME}
    RUNTIME DESTINATION bin
    LIBRARY DESTINATION lib
    ARCHIVE DESTINATION lib
)

# 打包规则
include(CPack)
set(CPACK_PACKAGE_NAME "MyWinUI3App")
set(CPACK_PACKAGE_VERSION "1.0.0")
set(CPACK_PACKAGE_VENDOR "MyCompany")
set(CPACK_PACKAGE_DESCRIPTION_SUMMARY "My WinUI 3 Application")
set(CPACK_GENERATOR "NSIS")

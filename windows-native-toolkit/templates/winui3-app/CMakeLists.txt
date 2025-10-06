cmake_minimum_required(VERSION 3.20)
project(SkybridgeCompassApp)

# 设置 C++ 标准
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 检测目标平台
if(WIN32)
    set(IS_WINDOWS TRUE)
    message(STATUS "Building for Windows platform")
else()
    set(IS_WINDOWS FALSE)
    message(STATUS "Cross-compiling for Windows from ${CMAKE_SYSTEM_NAME}")
endif()

# 设置输出目录
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)

# 查找 Windows SDK
if(IS_WINDOWS)
    find_package(WindowsSDK REQUIRED)
    set(USE_WINDOWS_SDK TRUE)
else()
    # 交叉编译时使用预编译的 SDK
    set(WINDOWS_SDK_PATH ${CMAKE_CURRENT_SOURCE_DIR}/../tools/windows-sdk)
    if(EXISTS ${WINDOWS_SDK_PATH})
        set(USE_WINDOWS_SDK TRUE)
        message(STATUS "Using pre-compiled Windows SDK: ${WINDOWS_SDK_PATH}")
    else()
        set(USE_WINDOWS_SDK FALSE)
        message(WARNING "Windows SDK not found, using fallback")
    endif()
endif()

# 查找 C++/WinRT
if(IS_WINDOWS)
    find_package(cppwinrt REQUIRED)
    set(USE_CPP_WINRT TRUE)
else()
    # 交叉编译时使用预编译的 C++/WinRT
    set(CPP_WINRT_PATH ${CMAKE_CURRENT_SOURCE_DIR}/../tools/cpp-winrt)
    if(EXISTS ${CPP_WINRT_PATH})
        set(USE_CPP_WINRT TRUE)
        message(STATUS "Using pre-compiled C++/WinRT: ${CPP_WINRT_PATH}")
    else()
        set(USE_CPP_WINRT FALSE)
        message(WARNING "C++/WinRT not found, using fallback")
    endif()
endif()

# 查找 WinUI 3
if(IS_WINDOWS)
    find_package(WinUI3 REQUIRED)
    set(USE_WINUI3 TRUE)
else()
    # 交叉编译时使用预编译的 WinUI 3
    set(WINUI3_PATH ${CMAKE_CURRENT_SOURCE_DIR}/../tools/winui3)
    if(EXISTS ${WINUI3_PATH})
        set(USE_WINUI3 TRUE)
        message(STATUS "Using pre-compiled WinUI 3: ${WINUI3_PATH}")
    else()
        set(USE_WINUI3 FALSE)
        message(WARNING "WinUI 3 not found, using fallback")
    endif()
endif()

# 包含目录
include_directories(${CMAKE_CURRENT_SOURCE_DIR}/src)

if(USE_WINDOWS_SDK)
    include_directories(${WINDOWS_SDK_INCLUDE_DIRS})
endif()

if(USE_CPP_WINRT)
    include_directories(${CPP_WINRT_INCLUDE_DIRS})
endif()

if(USE_WINUI3)
    include_directories(${WINUI3_INCLUDE_DIRS})
endif()

# 源文件
set(SOURCES
    src/main.cpp
    src/App.cpp
    src/MainWindow.cpp
    src/NetworkManager.cpp
    src/TelemetryManager.cpp
    src/DeviceDiscovery.cpp
    src/RemoteDesktop.cpp
    src/ETWTraceHelper.cpp
)

# 头文件
set(HEADERS
    src/App.h
    src/MainWindow.h
    src/NetworkManager.h
    src/TelemetryManager.h
    src/DeviceDiscovery.h
    src/RemoteDesktop.h
    src/ETWTraceHelper.h
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
    # 基础 Windows 库
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
    winhttp
    iphlpapi
    netapi32
    wtsapi32
    # 网络库
    ${CMAKE_CURRENT_SOURCE_DIR}/../libraries/network/winhttp_client
)

# 条件链接
if(USE_WINDOWS_SDK)
    target_link_libraries(${PROJECT_NAME} ${WINDOWS_SDK_LIBRARIES})
endif()

if(USE_CPP_WINRT)
    target_link_libraries(${PROJECT_NAME} ${CPP_WINRT_LIBRARIES})
endif()

if(USE_WINUI3)
    target_link_libraries(${PROJECT_NAME} ${WINUI3_LIBRARIES})
endif()

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

# 条件编译定义
if(USE_WINDOWS_SDK)
    target_compile_definitions(${PROJECT_NAME} PRIVATE USE_WINDOWS_SDK=1)
endif()

if(USE_CPP_WINRT)
    target_compile_definitions(${PROJECT_NAME} PRIVATE USE_CPP_WINRT=1)
endif()

if(USE_WINUI3)
    target_compile_definitions(${PROJECT_NAME} PRIVATE USE_WINUI3=1)
endif()

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
set(CPACK_PACKAGE_NAME "SkybridgeCompassApp")
set(CPACK_PACKAGE_VERSION "1.0.0")
set(CPACK_PACKAGE_VENDOR "SkybridgeCompass")
set(CPACK_PACKAGE_DESCRIPTION_SUMMARY "Skybridge Compass Windows Application")
set(CPACK_GENERATOR "NSIS")

# 创建配置头文件
configure_file(
    ${CMAKE_CURRENT_SOURCE_DIR}/src/config.h.in
    ${CMAKE_CURRENT_BINARY_DIR}/config.h
    @ONLY
)

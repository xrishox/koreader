cmake_minimum_required(VERSION 3.24)
project(KOReaderIOS LANGUAGES C OBJC)

set(CMAKE_OSX_DEPLOYMENT_TARGET "15.0" CACHE STRING "Minimum iOS version")

add_executable(KOReader
    KOReaderIOSMain.m
    LaunchScreen.storyboard
    ../icons/AppIcon60x60@2x.png
    ../icons/AppIcon60x60@3x.png
    ../icons/AppIcon76x76@2x.png
    ../icons/AppIcon83.5x83.5@2x.png
    ../icons/AppIcon1024.png
)

target_include_directories(KOReader PRIVATE
    "${KOREADER_STAGING_DIR}/include"
    "${KOREADER_STAGING_DIR}/include/luajit-2.1"
)

target_link_directories(KOReader PRIVATE
    "${KOREADER_STAGING_DIR}/lib"
)

target_link_libraries(KOReader PRIVATE
    luajit
    SDL3
    "-framework Foundation"
    "-framework UIKit"
    "-framework UniformTypeIdentifiers"
)

target_compile_options(KOReader PRIVATE
    $<$<COMPILE_LANGUAGE:OBJC>:-fobjc-arc>
)

set_target_properties(KOReader PROPERTIES
    MACOSX_BUNDLE TRUE
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_LIST_DIR}/../Info.plist"
    BUILD_WITH_INSTALL_RPATH TRUE
    INSTALL_RPATH "@executable_path/reader/libs"
    RESOURCE "LaunchScreen.storyboard;../icons/AppIcon60x60@2x.png;../icons/AppIcon60x60@3x.png;../icons/AppIcon76x76@2x.png;../icons/AppIcon83.5x83.5@2x.png;../icons/AppIcon1024.png"
)

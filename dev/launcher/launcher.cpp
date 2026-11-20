#include <windows.h>
#include <shellapi.h>

#include <cerrno>
#include <cwchar>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
const wchar_t title[] = L"冒险王之神兵传奇";

struct Handle {
    HANDLE value;
    explicit Handle(HANDLE handle) : value(handle) {}
    ~Handle() { if (value != INVALID_HANDLE_VALUE && value != nullptr) CloseHandle(value); }
    Handle(const Handle&) = delete;
    Handle& operator=(const Handle&) = delete;
};

void fail(const std::wstring& message) {
    throw message;
}

void systemError(const std::wstring& message, DWORD code) {
    fail(message + L"\nWindows 错误代码：" + std::to_wstring(code));
}

std::wstring packageDirectory() {
    std::vector<wchar_t> path(32768);
    const DWORD length = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
    if (length == 0 || length >= path.size()) {
        systemError(L"无法获取启动器的位置。", GetLastError());
    }
    const std::wstring executable(path.data(), length);
    return executable.substr(0, executable.find_last_of(L'\\') + 1);
}

void ensureDirectory(const std::wstring& path) {
    if (CreateDirectoryW(path.c_str(), nullptr)) return;
    const DWORD code = GetLastError();
    const DWORD attributes = GetFileAttributesW(path.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES || !(attributes & FILE_ATTRIBUTE_DIRECTORY)) {
        systemError(L"游戏目录需要可写，请将压缩包完整解压到可写目录。\n" + path, code);
    }
}

void requireFile(const std::wstring& path) {
    const DWORD attributes = GetFileAttributesW(path.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_DIRECTORY)) {
        fail(L"找不到游戏文件，请完整解压压缩包。\n" + path);
    }
}

void setVideoPreference(const std::wstring& path) {
    // The game uses MP3 audio and has no H.264 video. Prevent the runtime from downloading a codec.
    const char contents[] = "enable_openh264 = false\n";
    Handle file(CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                            FILE_ATTRIBUTE_NORMAL, nullptr));
    if (file.value == INVALID_HANDLE_VALUE) systemError(L"无法创建播放器设置。", GetLastError());
    DWORD written = 0;
    if (!WriteFile(file.value, contents, sizeof(contents) - 1, &written, nullptr) ||
        written != sizeof(contents) - 1) {
        systemError(L"无法写入播放器设置。", GetLastError());
    }
}

class Config {
public:
    explicit Config(const std::wstring& path) : path_(path) {}

    std::wstring get(const wchar_t* section, const wchar_t* key, const wchar_t* fallback) const {
        wchar_t value[128] = {};
        const DWORD length = GetPrivateProfileStringW(section, key, fallback, value, 128, path_.c_str());
        if (length == 127) invalid(section, key);
        return value;
    }

    int integer(const wchar_t* section, const wchar_t* key, const wchar_t* fallback,
                int minimum, int maximum) const {
        const std::wstring value = get(section, key, fallback);
        wchar_t* end = nullptr;
        errno = 0;
        const long number = std::wcstol(value.c_str(), &end, 10);
        if (end == value.c_str() || *end != L'\0' || errno == ERANGE ||
            number < minimum || number > maximum) {
            invalid(section, key);
        }
        return static_cast<int>(number);
    }

    void invalid(const wchar_t* section, const wchar_t* key) const {
        fail(std::wstring(L"game.ini 中 [") + section + L"] 的 " + key +
             L" 超出有效范围或格式有误。\n请参照便携包内的说明修改后重试。\n" + path_);
    }

private:
    std::wstring path_;
};

std::wstring directoryUrl(std::wstring path) {
    for (auto& character : path) {
        if (character == L'\\') character = L'/';
    }
    const int size = WideCharToMultiByte(CP_UTF8, 0, path.c_str(),
                                         static_cast<int>(path.size()), nullptr, 0, nullptr, nullptr);
    if (!size) systemError(L"无法转换游戏目录。", GetLastError());
    std::string utf8(size, '\0');
    WideCharToMultiByte(CP_UTF8, 0, path.c_str(), static_cast<int>(path.size()),
                        &utf8[0], size, nullptr, nullptr);
    const bool unc = path.compare(0, 2, L"//") == 0;
    std::wstring url = unc ? L"file:" : L"file:///";
    const wchar_t hex[] = L"0123456789ABCDEF";
    for (unsigned char byte : utf8) {
        if ((byte >= 'A' && byte <= 'Z') || (byte >= 'a' && byte <= 'z') ||
            (byte >= '0' && byte <= '9') || byte == '/' || byte == ':' || byte == '_' ||
            byte == '-' || byte == '.' || byte == '~') {
            url += static_cast<wchar_t>(byte);
        } else {
            url += L'%';
            url += hex[byte >> 4];
            url += hex[byte & 15];
        }
    }
    return url;
}

std::wstring quote(const std::wstring& argument) {
    std::wstring result = L"\"";
    size_t slashes = 0;
    for (wchar_t character : argument) {
        if (character == L'\\') {
            ++slashes;
            continue;
        }
        result.append(character == L'\"' ? 2 * slashes + 1 : slashes, L'\\');
        slashes = 0;
        result += character;
    }
    result.append(2 * slashes, L'\\');
    return result + L'\"';
}

bool debugSwitch() {
    int count = 0;
    wchar_t** arguments = CommandLineToArgvW(GetCommandLineW(), &count);
    if (!arguments) systemError(L"无法读取启动参数。", GetLastError());
    const bool debug = count == 2 && std::wcscmp(arguments[1], L"--debug") == 0;
    LocalFree(arguments);
    if (count != 1 && !debug) fail(L"支持的启动参数：--debug（开启游戏调试日志）。");
    return debug;
}

const wchar_t* playerArchitecture() {
    using IsWow64Process2 = BOOL (WINAPI*)(HANDLE, USHORT*, USHORT*);
    const HMODULE kernel = GetModuleHandleW(L"kernel32.dll");
    const auto architectureQuery = reinterpret_cast<IsWow64Process2>(
        GetProcAddress(kernel, "IsWow64Process2"));
    if (architectureQuery) {
        USHORT process = 0;
        USHORT native = 0;
        if (architectureQuery(GetCurrentProcess(), &process, &native)) {
            return native == IMAGE_FILE_MACHINE_AMD64 ? L"x64" : L"x86";
        }
    }
    SYSTEM_INFO system = SYSTEM_INFO();
    GetNativeSystemInfo(&system);
    return system.wProcessorArchitecture == PROCESSOR_ARCHITECTURE_AMD64 ? L"x64" : L"x86";
}

DWORD run(bool debug) {
    const std::wstring root = packageDirectory();
    const Config config(root + L"game.ini");
    const auto width = config.integer(L"Window", L"Width", L"960", 480, 3840);
    const auto height = config.integer(L"Window", L"Height", L"600", 300, 2160);
    const auto fullscreen = config.integer(L"Window", L"Fullscreen", L"0", 0, 1);
    const auto volume = config.integer(L"Window", L"Volume", L"100", 0, 100);
    const auto graphics = config.get(L"Window", L"Graphics", L"auto");
    if (graphics != L"auto" && graphics != L"dx12" && graphics != L"vulkan" && graphics != L"gl") {
        config.invalid(L"Window", L"Graphics");
    }
    const auto invincible = config.integer(L"Game", L"Invincible", L"1", 0, 1);
    const auto experience = config.integer(L"Game", L"ExperiencePerLevel", L"50", 0, 1000000);
    const bool debugEnabled = config.integer(L"Debug", L"Trace", L"0", 0, 1) != 0 || debug;

    const std::wstring runtime = root + L"runtime\\" + playerArchitecture() + L"\\ruffle.exe";
    const std::wstring game = root + L"game\\";
    const std::wstring entry = game + L"gameload.swf";
    requireFile(runtime);
    requireFile(entry);
    requireFile(game + L"game.swf");
    requireFile(game + L"files.xml");

    const std::wstring data = root + L"data";
    const std::wstring saves = data + L"\\saves";
    const std::wstring settings = data + L"\\runtime";
    const std::wstring cache = data + L"\\cache";
    ensureDirectory(data);
    Handle lock(CreateFileW((data + L"\\game.lock").c_str(), GENERIC_READ | GENERIC_WRITE, 0,
                            nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr));
    if (lock.value == INVALID_HANDLE_VALUE) {
        const DWORD code = GetLastError();
        if (code == ERROR_SHARING_VIOLATION) fail(L"这个目录中的游戏已在运行。");
        systemError(L"游戏目录需要可写，请将压缩包完整解压到可写目录。", code);
    }
    ensureDirectory(saves);
    ensureDirectory(settings);
    ensureDirectory(cache);
    setVideoPreference(settings + L"\\preferences.toml");

    const std::wstring audio = volume == 100 ? L"1" : L"0." + (volume < 10 ? std::wstring(L"0") : L"")
                                                            + std::to_wstring(volume);
    std::vector<std::wstring> args = {
        runtime, L"--no-gui", L"--width", std::to_wstring(width), L"--height", std::to_wstring(height),
        L"--volume", audio, L"--letterbox", L"on", L"--storage", L"disk", L"--save-directory", saves,
        L"--config", settings, L"--cache-directory", cache, L"--base", directoryUrl(game),
        L"--spoof-url", L"file:///AdventureKing/gameload.swf", L"--open-url-mode", L"deny",
        L"--tcp-connections", L"deny", L"--filesystem-access-mode", L"deny", L"--dummy-external-interface",
        L"-P", L"invincible=" + std::to_wstring(invincible),
        L"-P", L"experiencePerLevel=" + std::to_wstring(experience),
        L"-P", debugEnabled ? L"debug=1" : L"debug=0"
    };
    if (fullscreen) args.push_back(L"--fullscreen");
    if (graphics != L"auto") {
        args.push_back(L"--graphics");
        args.push_back(graphics);
    }
    args.push_back(entry);
    std::wstring command;
    for (const auto& argument : args) {
        if (!command.empty()) command += L' ';
        command += quote(argument);
    }
    std::vector<wchar_t> mutableCommand(command.begin(), command.end());
    mutableCommand.push_back(L'\0');

    const wchar_t* filters = debugEnabled
        ? L"warn,ruffle_desktop=info,ruffle_core::context=info,avm_trace=info"
        : L"warn,ruffle_desktop=info,avm_trace=info";
    if (!SetEnvironmentVariableW(L"RUST_LOG", filters)) {
        systemError(L"无法设置播放器日志。", GetLastError());
    }
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process{};
    if (!CreateProcessW(runtime.c_str(), mutableCommand.data(), nullptr, nullptr, FALSE, 0,
                        nullptr, game.c_str(), &startup, &process)) {
        systemError(L"无法启动游戏播放器。", GetLastError());
    }
    Handle child(process.hProcess);
    CloseHandle(process.hThread);
    if (WaitForSingleObject(child.value, INFINITE) != WAIT_OBJECT_0) {
        systemError(L"无法等待游戏播放器退出。", GetLastError());
    }
    DWORD exitCode = 0;
    if (!GetExitCodeProcess(child.value, &exitCode)) {
        systemError(L"无法读取游戏播放器的退出状态。", GetLastError());
    }
    if (exitCode) {
        fail(L"游戏播放器异常退出。退出代码：" + std::to_wstring(exitCode) +
             L"\n日志位置：" + cache + L"\\log\n若启动时黑屏，可在 game.ini 中切换 Graphics 后重试。");
    }
    return exitCode;
}
}

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
    try {
        return static_cast<int>(run(debugSwitch()));
    } catch (const std::wstring& message) {
        MessageBoxW(nullptr, message.c_str(), title, MB_OK | MB_ICONERROR);
    } catch (const std::exception&) {
        MessageBoxW(nullptr, L"启动器遇到意外错误。", title, MB_OK | MB_ICONERROR);
    }
    return 1;
}

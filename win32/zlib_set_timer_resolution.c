/*
 * zlib_set_timer_resolution.c
 * ------------------------------------------------------------------------
 * 从 zlib1.2.dll (64位 / zlib-ng 2.3.1, MinGW-w64 GCC 15.2 构建) 反汇编
 * 100% 还原的「DLL 加载时提高系统定时器精度」逻辑。
 *
 * 还原自以下两个函数：
 *   - 0x241bad2e0  set_timer_resolution()  —— 实际设置定时器精度
 *   - 0x241bad3b0  DllMain()               —— 在 DLL_PROCESS_ATTACH 时调用上者
 *
 * 行为：DLL 被进程加载时（DLL_PROCESS_ATTACH），通过 ntdll 的未公开接口
 *       NtSetTimerResolution 把系统定时器精度请求为 1ms（10000 个 100ns 单位）。
 *       （原 DLL 为 5ms，此处按需求统一改为 1ms。）
 *
 * 说明：
 *   - 原始 DLL 通过 GetModuleHandleW(L"ntdll.dll") + GetProcAddress 动态取
 *     NtQueryTimerResolution / NtSetTimerResolution，因此导入表里看不到它们。
 *   - DllMain 会忽略 set_timer_resolution() 的返回值，始终返回 TRUE。
 *
 * 合入方式：把本文件加入 zlib 的 DLL 构建（仅 Windows DLL 目标）。
 *   - MinGW/MSVC 编译为 zlib1.dll 的一部分即可，链接器会自动把 DllMain
 *     编进 _DllMainCRTStartup 的调用序列（与原 DLL 的注册方式一致）。
 *   - 仅依赖 kernel32，无需额外链接库。
 * ------------------------------------------------------------------------
 */

#ifdef _WIN32

#include <windows.h>

/*
 * ntdll 未公开接口的函数指针类型。
 * 返回值为 NTSTATUS (LONG)，0 (STATUS_SUCCESS) 表示成功。
 * 精度单位为 100ns。
 *
 *   NTSTATUS NtQueryTimerResolution(PULONG MinimumResolution,
 *                                   PULONG MaximumResolution,
 *                                   PULONG CurrentResolution);
 *   NTSTATUS NtSetTimerResolution  (ULONG  DesiredResolution,
 *                                   BOOLEAN SetResolution,
 *                                   PULONG CurrentResolution);
 */
typedef LONG (NTAPI *PFN_NtQueryTimerResolution)(PULONG, PULONG, PULONG);
typedef LONG (NTAPI *PFN_NtSetTimerResolution)(ULONG, BOOLEAN, PULONG);

/* 请求的定时器精度：0x2710 = 10000 个 100ns 单位 = 1,000,000 ns = 1ms
 * 注：原 DLL 此处为 0xC350(50000=5ms)，此处按需求统一改为 1ms。 */
#define ZLIB_DESIRED_TIMER_RESOLUTION_100NS  10000UL  /* 0x2710 = 1ms */

/*
 * 还原自 0x241bad2e0。
 * 返回 HRESULT（与原始反汇编完全一致：S_OK / E_NOTIMPL / E_FAIL /
 * HRESULT_FROM_WIN32(GetLastError())）。注意调用方 DllMain 会忽略该返回值。
 */
static HRESULT set_timer_resolution(void)
{
    HMODULE hNtdll;
    PFN_NtQueryTimerResolution pNtQueryTimerResolution;
    PFN_NtSetTimerResolution   pNtSetTimerResolution;

    /* 三个局部变量，初值 0 —— 对应 [rsp+0x24]/[rsp+0x28]/[rsp+0x2c] */
    ULONG MinimumResolution = 0;   /* [rsp+0x24] */
    ULONG MaximumResolution = 0;   /* [rsp+0x28] */
    ULONG CurrentResolution = 0;   /* [rsp+0x2c] */

    /* 0x241bad2e7: GetModuleHandleW(L"ntdll.dll")
     * 失败 -> 0x241bad378: return HRESULT_FROM_WIN32(GetLastError()); */
    hNtdll = GetModuleHandleW(L"ntdll.dll");
    if (hNtdll == NULL) {
        return HRESULT_FROM_WIN32(GetLastError());
    }

    /* 0x241bad31b: GetProcAddress(hNtdll, "NtQueryTimerResolution")
     * 为空 -> 0x241bad398: return 0x80004001 (E_NOTIMPL) */
    pNtQueryTimerResolution =
        (PFN_NtQueryTimerResolution)GetProcAddress(hNtdll, "NtQueryTimerResolution");
    if (pNtQueryTimerResolution == NULL) {
        return E_NOTIMPL; /* 0x80004001 */
    }

    /* 0x241bad332: GetProcAddress(hNtdll, "NtSetTimerResolution")
     * 为空 -> 0x241bad398: return 0x80004001 (E_NOTIMPL) */
    pNtSetTimerResolution =
        (PFN_NtSetTimerResolution)GetProcAddress(hNtdll, "NtSetTimerResolution");
    if (pNtSetTimerResolution == NULL) {
        return E_NOTIMPL; /* 0x80004001 */
    }

    /* 0x241bad352: NtQueryTimerResolution(&Minimum, &Maximum, &Current)
     *   rcx=&Minimum, rdx=&Maximum, r8=&Current
     * 非 0 -> 0x241bad3a0: return 0x80004005 (E_FAIL) */
    if (pNtQueryTimerResolution(&MinimumResolution,
                                &MaximumResolution,
                                &CurrentResolution) != 0) {
        return E_FAIL; /* 0x80004005 */
    }

    /* 0x241bad367: NtSetTimerResolution(10000, TRUE, &Current)
     *   rcx=0x2710(=10000,1ms), rdx=1(TRUE), r8=&Current
     *   注：原 DLL 此处为 50000(5ms)，按需求改为 1ms。
     * 非 0 -> 0x241bad3a0: return 0x80004005 (E_FAIL) */
    if (pNtSetTimerResolution(ZLIB_DESIRED_TIMER_RESOLUTION_100NS,
                              TRUE,
                              &CurrentResolution) != 0) {
        return E_FAIL; /* 0x80004005 */
    }

    /* 0x241bad36d: return S_OK; */
    return S_OK;
}

/*
 * ------------------------------------------------------------------------
 * 对称收尾（原 DLL 未实现，规范化补充）。
 * 在 DLL_PROCESS_DETACH 时调用，释放之前请求的高精度定时器，
 * 让系统定时器精度可以回退到默认值。
 *
 * 与 set 的唯一区别：NtSetTimerResolution 的第二个参数传 FALSE
 * 表示「撤销本进程对该精度的请求」（DesiredResolution 仍需与请求时一致）。
 * ------------------------------------------------------------------------
 */
static HRESULT release_timer_resolution(void)
{
    HMODULE hNtdll;
    PFN_NtSetTimerResolution pNtSetTimerResolution;
    ULONG CurrentResolution = 0;

    hNtdll = GetModuleHandleW(L"ntdll.dll");
    if (hNtdll == NULL) {
        return HRESULT_FROM_WIN32(GetLastError());
    }

    pNtSetTimerResolution =
        (PFN_NtSetTimerResolution)GetProcAddress(hNtdll, "NtSetTimerResolution");
    if (pNtSetTimerResolution == NULL) {
        return E_NOTIMPL; /* 0x80004001 */
    }

    /* 第二参数 FALSE = 撤销精度请求；DesiredResolution 与 set 时保持一致 */
    if (pNtSetTimerResolution(ZLIB_DESIRED_TIMER_RESOLUTION_100NS,
                              FALSE,
                              &CurrentResolution) != 0) {
        return E_FAIL; /* 0x80004005 */
    }

    return S_OK;
}

/*
 * 还原自 0x241bad3b0，并补充对称收尾。
 * 标准 DLL 入口：
 *   - DLL_PROCESS_ATTACH：调用 set_timer_resolution()  （还原原 DLL 行为）
 *   - DLL_PROCESS_DETACH：调用 release_timer_resolution() （新增规范化收尾）
 * 两者返回值均被忽略；任何情况下都返回 TRUE。
 *
 * 注意：若你的 zlib 工程中已存在 DllMain，请将下面 ATTACH / DETACH 两个
 *       分支里的调用合入到现有 DllMain 中，不要重复定义 DllMain。
 *
 * 关于 lpvReserved：在 DLL_PROCESS_DETACH 时，
 *   - lpvReserved == NULL 表示由 FreeLibrary 卸载（正常卸载，需要收尾）；
 *   - lpvReserved != NULL 表示进程正在退出（系统会直接回收，无需收尾）。
 *   因此仅在 lpvReserved == NULL 时执行释放，避免进程退出路径上的多余操作。
 */
BOOL WINAPI DllMain(HINSTANCE hinstDLL, DWORD fdwReason, LPVOID lpvReserved)
{
    (void)hinstDLL;

    switch (fdwReason) {
    case DLL_PROCESS_ATTACH:                 /* 0x241bad3b4: cmp edx, 1 */
        set_timer_resolution();              /* 0x241bad3c8: call 0x241bad2e0 (返回值忽略) */
        break;

//     case DLL_PROCESS_DETACH:
//         if (lpvReserved == NULL) {           /* 仅 FreeLibrary 卸载时才释放 */
//             release_timer_resolution();      /* 返回值忽略 */
//         }
//         break;

    default:
        break;
    }

    return TRUE;                             /* 0x241bad3cd: mov eax, 1 */
}

#endif /* _WIN32 */

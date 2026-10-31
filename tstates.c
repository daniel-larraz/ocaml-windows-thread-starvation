/* tstates.exe - observe Windows thread scheduling states of a child process.
 *
 * Built for ocaml/ocaml#15042.  The claim under test is that a domain which
 * has not finished its minor GC sits *runnable but not running* at dynamic
 * priority 8 while other domains spin in the STW retry loops at priority 9.
 * That is a statement about scheduler state and thread priority, so measure
 * exactly those: NtQuerySystemInformation(SystemProcessInformation) reports,
 * per thread, ThreadState, the current (boosted) Priority and BasePriority.
 *
 * Needs no admin rights and no ETW/WPT install, so it runs unchanged on a
 * GitHub Actions windows runner.
 *
 * Usage:
 *   tstates.exe [--mask <hex>] [--noboost] [--interval <ms>]
 *               [--threshold <ms>] [--seconds <n>] [--sampler-mask <hex>]
 *               -- <command> [args...]
 *
 *   --mask          affinity mask for the CHILD (as pin.exe's hexmask)
 *   --noboost       SetProcessPriorityBoost(child, TRUE), i.e. disable boosts
 *   --interval      target sampling period, ms (default 2)
 *   --threshold     report runnable-not-running episodes at least this long,
 *                   ms (default 50, matching stall.ml's own 50ms bucket)
 *   --seconds       stop sampling after this long (default: until child exits)
 *   --sampler-mask  affinity mask for the sampler itself; on a machine with
 *                   more processors than the child's mask, pin the sampler to
 *                   the others so it keeps sampling through the child's storm
 *
 * Example, mirroring the thread's repro:
 *   tstates.exe --mask F --sampler-mask F0 --threshold 50 -- stall.exe 11 3 20
 *
 * Example on a 4-processor runner (nothing to spare; sampler runs at high
 * priority instead):
 *   tstates.exe --mask F --threshold 50 -- stall.exe 11 3 20
 */

#define _WIN32_WINNT 0x0601
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- the bits of ntdll's process/thread enumeration we need -------------- */

typedef LONG KPRIORITY;

typedef struct { HANDLE UniqueProcess, UniqueThread; } MY_CLIENT_ID;
typedef struct { USHORT Length, MaximumLength; PWSTR Buffer; } MY_USTRING;

typedef struct {
  LARGE_INTEGER KernelTime, UserTime, CreateTime;
  ULONG         WaitTime;
  PVOID         StartAddress;
  MY_CLIENT_ID  ClientId;
  KPRIORITY     Priority;
  LONG          BasePriority;
  ULONG         ContextSwitches, ThreadState, WaitReason;
} MY_THREAD_INFO;

typedef struct {
  ULONG         NextEntryOffset, NumberOfThreads;
  LARGE_INTEGER WorkingSetPrivateSize;
  ULONG         HardFaultCount, NumberOfThreadsHighWatermark;
  ULONGLONG     CycleTime;
  LARGE_INTEGER CreateTime, UserTime, KernelTime;
  MY_USTRING    ImageName;
  KPRIORITY     BasePriority;
  HANDLE        UniqueProcessId, InheritedFromUniqueProcessId;
  ULONG         HandleCount, SessionId;
  ULONG_PTR     UniqueProcessKey;
  SIZE_T        PeakVirtualSize, VirtualSize;
  ULONG         PageFaultCount;
  SIZE_T        PeakWorkingSetSize, WorkingSetSize,
                QuotaPeakPagedPoolUsage, QuotaPagedPoolUsage,
                QuotaPeakNonPagedPoolUsage, QuotaNonPagedPoolUsage,
                PagefileUsage, PeakPagefileUsage, PrivatePageCount;
  LARGE_INTEGER ReadOperationCount, WriteOperationCount, OtherOperationCount,
                ReadTransferCount, WriteTransferCount, OtherTransferCount;
} MY_PROCESS_INFO;

#define SystemProcessInformation 5
#define STATUS_INFO_LENGTH_MISMATCH ((LONG)0xC0000004L)

typedef LONG (WINAPI *PFN_NTQSI)(ULONG, PVOID, ULONG, PULONG);

/* KTHREAD_STATE */
#define TS_INITIALIZED 0
#define TS_READY       1
#define TS_RUNNING     2
#define TS_STANDBY     3
#define TS_TERMINATED  4
#define TS_WAITING     5
#define TS_TRANSITION  6
#define TS_DEFERRED    7

/* Runnable but not on a processor: this is the state the bug is about. */
static int runnable_not_running(ULONG st)
{
  return st == TS_READY || st == TS_STANDBY || st == TS_DEFERRED;
}

static const char *state_name(ULONG st)
{
  switch (st) {
  case TS_INITIALIZED: return "init";
  case TS_READY:       return "ready";
  case TS_RUNNING:     return "running";
  case TS_STANDBY:     return "standby";
  case TS_TERMINATED:  return "term";
  case TS_WAITING:     return "waiting";
  case TS_TRANSITION:  return "transit";
  case TS_DEFERRED:    return "defready";
  default:             return "?";
  }
}

/* ---- per-thread accounting ---------------------------------------------- */

#define MAX_THREADS 512
#define SNAP 160

typedef struct {
  ULONGLONG tid;
  int    live;
  int    seen;
  /* current runnable-not-running episode */
  int    in_episode;
  double ep_start;          /* seconds */
  LONG   ep_prio, ep_base;  /* priority when the episode began */
  LONG   ep_max_runner;     /* highest priority seen running during episode */
  int    ep_runners;        /* running-thread count at episode start */
  char   ep_snap[SNAP];     /* who was running when it began */
  /* totals */
  double ready_total, worst_ready;
  int    episodes, over_threshold;
  int    samples, n_running, n_ready, n_waiting;
  LONG   last_prio, last_base, min_prio, max_prio;
} TH;

static TH ths[MAX_THREADS];
static int nths = 0;

static TH *find_thread(ULONGLONG tid)
{
  for (int i = 0; i < nths; i++)
    if (ths[i].tid == tid) return &ths[i];
  if (nths == MAX_THREADS) return NULL;
  TH *t = &ths[nths++];
  memset(t, 0, sizeof *t);
  t->tid = tid;
  t->live = 1;
  t->min_prio = 1000;
  t->max_prio = -1000;
  return t;
}

/* ---- timing -------------------------------------------------------------- */

static double qpc_freq;

static double now_s(void)
{
  LARGE_INTEGER c;
  QueryPerformanceCounter(&c);
  return (double)c.QuadPart / qpc_freq;
}

/* ---- child command line -------------------------------------------------- */

static void append_arg(wchar_t *buf, size_t cap, const wchar_t *a)
{
  size_t n = wcslen(buf);
  int q = (wcschr(a, L' ') != NULL);
  if (n && n + 1 < cap) { buf[n++] = L' '; buf[n] = 0; }
  if (q && n + 1 < cap) { buf[n++] = L'"'; buf[n] = 0; }
  wcsncat(buf, a, cap - wcslen(buf) - 1);
  if (q) {
    n = wcslen(buf);
    if (n + 1 < cap) { buf[n++] = L'"'; buf[n] = 0; }
  }
}

int main(void)
{
  int argc;
  LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (!argv) { fprintf(stderr, "CommandLineToArgvW failed\n"); return 2; }

  DWORD_PTR child_mask = 0, sampler_mask = 0;
  int noboost = 0, sampler_normal = 0;
  double interval_ms = 2.0, threshold_ms = 50.0, limit_s = -1.0;
  int i = 1;

  for (; i < argc; i++) {
    if (!wcscmp(argv[i], L"--")) { i++; break; }
    else if (!wcscmp(argv[i], L"--mask") && i + 1 < argc)
      child_mask = _wcstoui64(argv[++i], NULL, 16);
    else if (!wcscmp(argv[i], L"--sampler-mask") && i + 1 < argc)
      sampler_mask = _wcstoui64(argv[++i], NULL, 16);
    else if (!wcscmp(argv[i], L"--noboost")) noboost = 1;
    else if (!wcscmp(argv[i], L"--sampler-normal")) sampler_normal = 1;
    else if (!wcscmp(argv[i], L"--interval") && i + 1 < argc)
      interval_ms = wcstod(argv[++i], NULL);
    else if (!wcscmp(argv[i], L"--threshold") && i + 1 < argc)
      threshold_ms = wcstod(argv[++i], NULL);
    else if (!wcscmp(argv[i], L"--seconds") && i + 1 < argc)
      limit_s = wcstod(argv[++i], NULL);
    else { fprintf(stderr, "unknown option\n"); return 2; }
  }
  if (i >= argc) {
    fprintf(stderr,
      "usage: tstates [--mask hex] [--sampler-mask hex] [--noboost]\n"
      "               [--interval ms] [--threshold ms] [--seconds n]\n"
      "               -- <command> [args...]\n");
    return 2;
  }

  static wchar_t cl[32768];
  cl[0] = 0;
  for (int k = i; k < argc; k++) append_arg(cl, 32768, argv[k]);

  PFN_NTQSI NtQSI = (PFN_NTQSI)(void *)GetProcAddress(
      GetModuleHandleW(L"ntdll.dll"), "NtQuerySystemInformation");
  if (!NtQSI) { fprintf(stderr, "no NtQuerySystemInformation\n"); return 2; }

  LARGE_INTEGER f;
  QueryPerformanceFrequency(&f);
  qpc_freq = (double)f.QuadPart;

  /* The sampler must keep running while the child saturates its processors,
     so by default it runs at HIGH_PRIORITY_CLASS (base priority 13).  That
     is itself a confound when the sampler shares processors with the child:
     at priority 13 it preempts the child's priority 8-9 threads and can
     manufacture the very inversion we are looking for.  Prefer
     --sampler-mask to give the sampler its own processors; where none are
     spare, cross-check with --sampler-normal. */
  if (!sampler_normal)
    SetPriorityClass(GetCurrentProcess(), HIGH_PRIORITY_CLASS);
  if (sampler_mask) SetProcessAffinityMask(GetCurrentProcess(), sampler_mask);

  STARTUPINFOW si = { sizeof si };
  PROCESS_INFORMATION pi;
  if (!CreateProcessW(NULL, cl, NULL, NULL, TRUE, CREATE_SUSPENDED,
                      NULL, NULL, &si, &pi)) {
    fprintf(stderr, "CreateProcess failed %lu\n", GetLastError());
    return 2;
  }
  if (child_mask && !SetProcessAffinityMask(pi.hProcess, child_mask))
    fprintf(stderr, "SetProcessAffinityMask failed %lu\n", GetLastError());
  if (noboost && !SetProcessPriorityBoost(pi.hProcess, TRUE))
    fprintf(stderr, "SetProcessPriorityBoost failed %lu\n", GetLastError());

  ULONGLONG target = (ULONGLONG)(ULONG_PTR)pi.dwProcessId;
  printf("tstates: pid %llu, child mask %llx, sampler mask %llx, boost %s, "
         "sampler %s\n",
         target, (unsigned long long)child_mask,
         (unsigned long long)sampler_mask, noboost ? "off" : "on",
         sampler_normal ? "normal priority" : "HIGH priority (base 13)");
  printf("tstates: sampling every ~%.1f ms, reporting runnable-not-running "
         "episodes >= %.0f ms\n\n", interval_ms, threshold_ms);
  fflush(stdout);

  ResumeThread(pi.hThread);

  ULONG cap = 1 << 20;
  BYTE *buf = malloc(cap);
  if (!buf) { fprintf(stderr, "oom\n"); return 2; }

  double t0 = now_s(), prev = t0, worst_gap = 0.0, gap_sum = 0.0;
  int nsamples = 0, missed = 0;
  double threshold = threshold_ms / 1000.0;

  for (;;) {
    if (WaitForSingleObject(pi.hProcess, 0) == WAIT_OBJECT_0) break;
    double t = now_s();
    if (limit_s > 0 && t - t0 >= limit_s) break;

    ULONG need = 0;
    LONG st;
    for (;;) {
      st = NtQSI(SystemProcessInformation, buf, cap, &need);
      if (st == STATUS_INFO_LENGTH_MISMATCH) {
        ULONG grow = need ? need + (need / 4) : cap * 2;
        BYTE *nb = realloc(buf, grow);
        if (!nb) { fprintf(stderr, "oom\n"); return 2; }
        buf = nb; cap = grow;
        continue;
      }
      break;
    }
    if (st < 0) { missed++; Sleep(1); continue; }

    /* locate the child */
    MY_PROCESS_INFO *p = (MY_PROCESS_INFO *)buf;
    MY_THREAD_INFO *thr = NULL;
    ULONG nthr = 0;
    for (;;) {
      if ((ULONGLONG)(ULONG_PTR)p->UniqueProcessId == target) {
        thr = (MY_THREAD_INFO *)((BYTE *)p + sizeof(MY_PROCESS_INFO));
        nthr = p->NumberOfThreads;
        break;
      }
      if (!p->NextEntryOffset) break;
      p = (MY_PROCESS_INFO *)((BYTE *)p + p->NextEntryOffset);
    }
    if (!thr) { Sleep(1); continue; }

    double sample_t = now_s();
    double gap = sample_t - prev;
    if (nsamples) {
      if (gap > worst_gap) worst_gap = gap;
      gap_sum += gap;
    }
    prev = sample_t;
    nsamples++;

    /* pass 1: who is on a processor, and at what priority */
    LONG max_runner = -1000;
    int runners = 0;
    char snap[SNAP];
    snap[0] = 0;
    for (ULONG k = 0; k < nthr; k++) {
      if (thr[k].ThreadState == TS_RUNNING) {
        runners++;
        if (thr[k].Priority > max_runner) max_runner = thr[k].Priority;
        size_t l = strlen(snap);
        if (l < SNAP - 24)
          snprintf(snap + l, SNAP - l, "%s%llu@%ld", l ? " " : "",
                   (unsigned long long)(ULONG_PTR)thr[k].ClientId.UniqueThread,
                   (long)thr[k].Priority);
      }
    }

    for (int k = 0; k < nths; k++) ths[k].seen = 0;

    /* pass 2: account each thread */
    for (ULONG k = 0; k < nthr; k++) {
      ULONGLONG tid =
        (ULONGLONG)(ULONG_PTR)thr[k].ClientId.UniqueThread;
      TH *t = find_thread(tid);
      if (!t) continue;
      t->seen = 1;
      t->samples++;
      t->last_prio = thr[k].Priority;
      t->last_base = thr[k].BasePriority;
      if (thr[k].Priority < t->min_prio) t->min_prio = thr[k].Priority;
      if (thr[k].Priority > t->max_prio) t->max_prio = thr[k].Priority;

      ULONG s = thr[k].ThreadState;
      if (s == TS_RUNNING) t->n_running++;
      else if (runnable_not_running(s)) t->n_ready++;
      else if (s == TS_WAITING) t->n_waiting++;

      if (runnable_not_running(s)) {
        if (!t->in_episode) {
          t->in_episode = 1;
          t->ep_start = sample_t;
          t->ep_prio = thr[k].Priority;
          t->ep_base = thr[k].BasePriority;
          t->ep_max_runner = max_runner;
          t->ep_runners = runners;
          strncpy(t->ep_snap, snap, SNAP - 1);
          t->ep_snap[SNAP - 1] = 0;
        } else if (max_runner > t->ep_max_runner) {
          t->ep_max_runner = max_runner;
        }
      } else if (t->in_episode) {
        double d = sample_t - t->ep_start;
        t->in_episode = 0;
        t->episodes++;
        t->ready_total += d;
        if (d > t->worst_ready) t->worst_ready = d;
        if (d >= threshold) {
          t->over_threshold++;
          printf("READY tid=%-6llu prio=%ld base=%ld  held %8.1f ms  "
                 "| top running prio %ld, %d on cpu  | at start: %s\n",
                 (unsigned long long)t->tid, (long)t->ep_prio,
                 (long)t->ep_base, d * 1000.0, (long)t->ep_max_runner,
                 t->ep_runners, t->ep_snap);
          fflush(stdout);
        }
      }
    }

    /* threads that vanished: close any open episode */
    for (int k = 0; k < nths; k++) {
      if (!ths[k].seen && ths[k].in_episode) {
        double d = sample_t - ths[k].ep_start;
        ths[k].in_episode = 0;
        ths[k].episodes++;
        ths[k].ready_total += d;
        if (d > ths[k].worst_ready) ths[k].worst_ready = d;
      }
      if (!ths[k].seen) ths[k].live = 0;
    }

    double spent = now_s() - t;
    double rest = interval_ms / 1000.0 - spent;
    if (rest > 0.0005) Sleep((DWORD)(rest * 1000.0));
  }

  WaitForSingleObject(pi.hProcess, INFINITE);
  DWORD code = 0;
  GetExitCodeProcess(pi.hProcess, &code);

  double span = now_s() - t0;
  printf("\n--- sampling ---------------------------------------------\n");
  printf("%d samples over %.1fs; mean %.2f ms, worst gap %.1f ms"
         "%s\n", nsamples, span,
         nsamples > 1 ? gap_sum / (nsamples - 1) * 1000.0 : 0.0,
         worst_gap * 1000.0,
         missed ? " (some queries failed)" : "");
  if (worst_gap > threshold / 2)
    printf("NOTE worst sampling gap is large relative to the threshold; "
           "episodes shorter than ~%.0f ms are not resolved reliably.\n",
           worst_gap * 1000.0 * 2);

  printf("\n--- per-thread, worst runnable-not-running episode first ---\n");
  printf("%-8s %7s %7s %7s %7s %8s %8s %6s %5s\n",
         "tid", "%run", "%ready", "%wait", "prio", "worstms", "readyms",
         "eps", ">=thr");
  /* selection sort by worst_ready, descending */
  for (int a = 0; a < nths; a++) {
    int best = a;
    for (int b = a + 1; b < nths; b++)
      if (ths[b].worst_ready > ths[best].worst_ready) best = b;
    TH tmp = ths[a]; ths[a] = ths[best]; ths[best] = tmp;

    TH *t = &ths[a];
    if (!t->samples) continue;
    char pr[32];
    if (t->min_prio == t->max_prio) snprintf(pr, sizeof pr, "%ld",
                                             (long)t->max_prio);
    else snprintf(pr, sizeof pr, "%ld-%ld", (long)t->min_prio,
                  (long)t->max_prio);
    printf("%-8llu %6.1f%% %6.1f%% %6.1f%% %7s %8.1f %8.0f %6d %5d\n",
           (unsigned long long)t->tid,
           100.0 * t->n_running / t->samples,
           100.0 * t->n_ready   / t->samples,
           100.0 * t->n_waiting / t->samples,
           pr, t->worst_ready * 1000.0, t->ready_total * 1000.0,
           t->episodes, t->over_threshold);
  }

  printf("\nchild exit code %lu\n", code);
  printf("\nRead it like this: the reported mechanism predicts at least one\n"
         "thread with a long worst-episode at a priority BELOW the top\n"
         "running priority shown on its READY lines.  Equal priorities, or\n"
         "high %%wait instead of %%ready, do not fit that mechanism.\n");
  return 0;
}

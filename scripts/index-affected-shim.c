// index-affected-shim.c — libIndexStore 的纯指针 ABI 垫片。
// Swift 的 @convention(c) 不能表达按值返回的 C 结构体(indexstore_string_ref_t),
// 本垫片把 index-affected.swift 用到的小面翻成「纯指针 + 标量」签名;
// 字符串经调用方缓冲区拷出。由 index-affected.swift 按需 clang 编译到
// <repo>/build/index-affected-shim.dylib(源 mtime 缓存)后 dlopen;
// 本垫片自身 dlopen libIndexStore(路径由 ia_load 传入),零链接期工具链耦合。
//
// libIndexStore 原型依据(indexstore-db 公开头快照,详见 index-affected.swift 头):
//   Sources/IndexStoreCAPI/include/IndexStoreCAPI/indexstore_functions.h

#include <dlfcn.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

typedef void *indexstore_t, *indexstore_error_t, *indexstore_symbol_t,
            *indexstore_occurrence_t, *indexstore_record_reader_t;
/// C indexstore_string_ref_t 的 ABI 镜像({data, length} 按值返回)。
typedef struct { const char *data; size_t length; } ia_string_ref_t;
typedef bool (*ia_occ_applier_t)(void *ctx, indexstore_occurrence_t);

static indexstore_t (*s_store_create)(const char *, indexstore_error_t *);
static indexstore_record_reader_t (*s_reader_create)(indexstore_t, const char *, indexstore_error_t *);
static void (*s_reader_dispose)(indexstore_record_reader_t);
static bool (*s_occ_apply)(indexstore_record_reader_t, void *, ia_occ_applier_t);
static uint64_t (*s_occ_roles)(indexstore_occurrence_t);
static indexstore_symbol_t (*s_occ_symbol)(indexstore_occurrence_t);
static ia_string_ref_t (*s_sym_usr)(indexstore_symbol_t);
static ia_string_ref_t (*s_sym_name)(indexstore_symbol_t);
static int32_t (*s_sym_kind)(indexstore_symbol_t);
// unit 面:record 名经 unit 依赖(kind=RECORD)拿 store 自己报告的名字,
// 对命名形状免疫(裸绝对路径假设实测 0/262,2026-11-03)。
static bool (*s_units_apply)(indexstore_t, unsigned, void *, bool (*)(void *, ia_string_ref_t));
static void *(*s_unit_reader_create)(indexstore_t, const char *, indexstore_error_t *);
static void (*s_unit_reader_dispose)(void *);
static bool (*s_unit_deps_apply)(void *, void *, bool (*)(void *, void *));
static uint32_t (*s_dep_kind)(void *);
static ia_string_ref_t (*s_dep_filepath)(void *);
static ia_string_ref_t (*s_dep_name)(void *);

static size_t copy_ref(ia_string_ref_t r, char *buf, size_t buf_size);

bool ia_load(const char *libindexstore_path) {
  void *h = dlopen(libindexstore_path, RTLD_NOW);
  if (!h) return false;
#define IA_LOAD(var, name) \
  do { *(void **)(&var) = dlsym(h, name); if (!(var)) return false; } while (0)
  IA_LOAD(s_store_create, "indexstore_store_create");
  IA_LOAD(s_reader_create, "indexstore_record_reader_create");
  IA_LOAD(s_reader_dispose, "indexstore_record_reader_dispose");
  IA_LOAD(s_occ_apply, "indexstore_record_reader_occurrences_apply_f");
  IA_LOAD(s_occ_roles, "indexstore_occurrence_get_roles");
  IA_LOAD(s_occ_symbol, "indexstore_occurrence_get_symbol");
  IA_LOAD(s_sym_usr, "indexstore_symbol_get_usr");
  IA_LOAD(s_sym_name, "indexstore_symbol_get_name");
  IA_LOAD(s_sym_kind, "indexstore_symbol_get_kind");
  IA_LOAD(s_units_apply, "indexstore_store_units_apply_f");
  IA_LOAD(s_unit_reader_create, "indexstore_unit_reader_create");
  IA_LOAD(s_unit_reader_dispose, "indexstore_unit_reader_dispose");
  IA_LOAD(s_unit_deps_apply, "indexstore_unit_reader_dependencies_apply_f");
  IA_LOAD(s_dep_kind, "indexstore_unit_dependency_get_kind");
  IA_LOAD(s_dep_filepath, "indexstore_unit_dependency_get_filepath");
  IA_LOAD(s_dep_name, "indexstore_unit_dependency_get_name");
  return true;
}

/// units 枚举的 name 是按值 string_ref,trampoline 拷进静态缓冲再回调
/// (单线程脚本,回调内同步消费;sorted=0)。
typedef bool (*ia_name_cb_t)(void *ctx, const char *unit_name);
static ia_name_cb_t g_name_cb;
static char g_name_buf[8192];
static bool units_trampoline(void *ctx, ia_string_ref_t name) {
  size_t n = name.length < sizeof(g_name_buf) - 1 ? name.length : sizeof(g_name_buf) - 1;
  if (name.data && n) memcpy(g_name_buf, name.data, n);
  g_name_buf[n] = '\0';
  return g_name_cb(ctx, g_name_buf);
}
bool ia_units_apply(void *store, void *ctx, ia_name_cb_t cb) {
  g_name_cb = cb;
  return s_units_apply(store, 0, ctx, units_trampoline);
}

void *ia_unit_reader_create(void *store, const char *unit_name) {
  return s_unit_reader_create(store, unit_name, NULL);
}
void ia_unit_reader_dispose(void *ur) { s_unit_reader_dispose(ur); }
bool ia_unit_deps_apply(void *ur, void *ctx, bool (*cb)(void *, void *)) { return s_unit_deps_apply(ur, ctx, cb); }
uint32_t ia_dep_kind(void *dep) { return s_dep_kind(dep); }
size_t ia_dep_filepath(void *dep, char *buf, size_t buf_size) { return copy_ref(s_dep_filepath(dep), buf, buf_size); }
/// record 依赖的 name(如 "Foo.swift-38QI52BNQY8ZV")——record_reader_create 吃的是它,不是 filepath。
size_t ia_dep_name(void *dep, char *buf, size_t buf_size) { return copy_ref(s_dep_name(dep), buf, buf_size); }

void *ia_store_create(const char *path) { return s_store_create(path, NULL); }
void *ia_reader_create(void *store, const char *record_name) { return s_reader_create(store, record_name, NULL); }
void ia_reader_dispose(void *reader) { s_reader_dispose(reader); }
bool ia_occurrences_apply(void *reader, void *ctx, ia_occ_applier_t cb) { return s_occ_apply(reader, ctx, cb); }
uint64_t ia_occurrence_roles(void *occ) { return s_occ_roles(occ); }
void *ia_occurrence_symbol(void *occ) { return s_occ_symbol(occ); }
int32_t ia_symbol_kind(void *sym) { return s_sym_kind(sym); }

/// 经缓冲区拷出,规避结构体按值返回;返回完整长度(截断时 > 拷出长度)。
static size_t copy_ref(ia_string_ref_t r, char *buf, size_t buf_size) {
  if (buf_size == 0) return r.length;
  if (!r.data || r.length == 0) { buf[0] = '\0'; return 0; }
  size_t n = r.length < buf_size - 1 ? r.length : buf_size - 1;
  memcpy(buf, r.data, n);
  buf[n] = '\0';
  return r.length;
}

size_t ia_symbol_usr(void *sym, char *buf, size_t buf_size) { return copy_ref(s_sym_usr(sym), buf, buf_size); }
size_t ia_symbol_name(void *sym, char *buf, size_t buf_size) { return copy_ref(s_sym_name(sym), buf, buf_size); }

/*
 * Minimal static SQLite executor for droid-kit.
 *
 * Android's /system/bin/sqlite3 aborts in reDroid while initializing ICU
 * collators. This tool links SQLite statically without ICU and is used to
 * preconfigure LSPosed's modules_config.db before lspd starts.
 *
 * Usage: sqlrun <db> <sql> [<sql> ...]
 */
#include <sqlite3.h>
#include <stdio.h>

static int print_row(void *unused, int argc, char **argv, char **cols) {
    (void) unused;
    (void) cols;
    for (int i = 0; i < argc; i++)
        printf("%s%s", i ? "|" : "", argv[i] ? argv[i] : "NULL");
    printf("\n");
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <db> <sql> [<sql> ...]\n", argv[0]);
        return 2;
    }

    sqlite3 *db = NULL;
    char *err = NULL;
    if (sqlite3_open(argv[1], &db) != SQLITE_OK) {
        fprintf(stderr, "sqlrun: open: %s\n", sqlite3_errmsg(db));
        sqlite3_close(db);
        return 1;
    }
    sqlite3_busy_timeout(db, 5000);

    for (int i = 2; i < argc; i++) {
        if (sqlite3_exec(db, argv[i], print_row, NULL, &err) != SQLITE_OK) {
            fprintf(stderr, "sqlrun: %s\n", err ? err : "unknown error");
            sqlite3_free(err);
            sqlite3_close(db);
            return 1;
        }
    }

    sqlite3_close(db);
    return 0;
}
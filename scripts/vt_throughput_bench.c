/*
 * Parse throughput for libghostty-vt, to compare against the SwiftTerm engine the app
 * ships with. Both are fed the same frame: a 105x95 grid where every cell carries a
 * truecolor foreground, a truecolor background, and an upper-half block, which is what a
 * terminal video player such as chafa emits when it draws with characters.
 *
 * Build libghostty-vt at the pinned commit, then this:
 *
 *   scripts/build_ghostty_vt.sh
 *   cc -O2 scripts/vt_throughput_bench.c -Ibuild/ghostty-out/include \
 *      build/ghostty-out/lib/libghostty-vt.a -o build/vtbench && build/vtbench
 *
 * The SwiftTerm side of the comparison is measured by feeding the same bytes to
 * SwiftTermEngine in a release build of the TerminalCore tests.
 */
#include <ghostty/vt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

int main(void) {
    const int cols = 105, rows = 95, frames = 30;
    char *buf = malloc(2 * 1024 * 1024);
    size_t len = 0;
    for (int row = 0; row < rows; row++) {
        len += sprintf(buf + len, "\x1b[%d;1H", row + 1);
        for (int col = 0; col < cols; col++) {
            int r = (row * 7 + col * 3) % 256, g = (row * 11 + col * 5) % 256, b = (row * 13 + col * 17) % 256;
            len += sprintf(buf + len, "\x1b[38;2;%d;%d;%dm\x1b[48;2;%d;%d;%dm\xe2\x96\x80", r, g, b, b, r, g);
        }
    }

    GhosttyTerminal term;
    if (ghostty_terminal_new(NULL, &term, cols, rows) != GHOSTTY_SUCCESS) {
        fprintf(stderr, "terminal_new failed\n");
        return 1;
    }
    ghostty_terminal_vt_write(term, (const uint8_t *)buf, len);

    double start = now_ms();
    for (int i = 0; i < frames; i++) ghostty_terminal_vt_write(term, (const uint8_t *)buf, len);
    double elapsed = now_ms() - start;

    printf("GHOSTTY bytesPerFrame=%zu frames=%d total=%.1fms perFrame=%.2fms throughput=%.1fMB/s\n",
           len, frames, elapsed, elapsed / frames, (len * (double)frames / 1e6) / (elapsed / 1000.0));
    ghostty_terminal_free(term);
    free(buf);
    return 0;
}

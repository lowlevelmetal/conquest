#ifndef CONQUEST_LOG_H
#define CONQUEST_LOG_H

/* Directory containing the game executable, with trailing backslash. */
const char *game_dir(void);

void log_init(void);
void log_printf(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

#endif

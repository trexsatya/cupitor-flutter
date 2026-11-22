#ifndef CUPITOR_ADBLOCK_H
#define CUPITOR_ADBLOCK_H
char * _Nullable cupitor_adblock_initialize(const char * _Nonnull directory, const char * _Nonnull platform);
char * _Nullable cupitor_adblock_query(const char * _Nonnull input);
void cupitor_adblock_free(char * _Nullable value);
#endif

// Жест «смахивание от левого края трекпада» через приватный MultitouchSupport.framework.
// Подключается динамически (dlopen): если фреймворк недоступен — просто возвращает 0 устройств.
#import <Foundation/Foundation.h>

typedef void (^TouchSwipeHandler)(void);

/// Запустить слежение. fingers — сколько пальцев, edge — «край» в долях ширины (0.03 = 3 %),
/// distance — минимальный путь вправо в долях ширины, window — за сколько секунд.
/// Возвращает число найденных мультитач-устройств; 0 — жест недоступен.
int  TouchStart(int fingers, double edge, double distance, double window, TouchSwipeHandler handler);
/// Пересоздать подписку (после сна устройства молчат).
void TouchRestart(void);
/// Печатать кадры в stdout — проверить, что жест вообще виден.
int  TouchDebug(void);
/// Для самопроверки: подать синтетический кадр (n пальцев, нормализованные x/y, время, базовый id).
void TouchSimulate(int n, const float *xs, const float *ys, double ts, int baseId);

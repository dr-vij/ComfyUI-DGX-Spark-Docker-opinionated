# DGX Spark: стабильность, тепло, зависания

Рабочие заметки от **2026-08-25**. Собрано в ходе разбора зависаний хоста и
доработки `spark-helper.sh`. Всё измерено на живой машине через read-only
диагностику; ничего на хосте не применялось.

---

## 1. Железо и базовые цифры

| Параметр | Значение |
|---|---|
| Хост | `spark-ae29`, NVIDIA DGX Spark / P4242 |
| BIOS | 5.36_0ACUM018 (08.06.2025) |
| Ядро | 6.17.0-1031-nvidia |
| Драйвер / CUDA | 580.173.02 / 13.0 |
| GPU | NVIDIA GB10 |
| RAM | 121 GB unified |
| Диск | Samsung MZALC4T0HBL1-00B07, 3.7 TB NVMe |

### GPU: частоты

| | MHz |
|---|---|
| Аппаратный максимум (graphics/SM/video) | **3003** |
| Штатный boost (Default Applications Clocks) | **2418** |
| Текущий кап в `spark-helper.sh` | 2100 |

- `Supported Clocks` драйвер для GB10 не отдаёт (`N/A`) — дискретную сетку
  допустимых частот посмотреть нельзя, `-lgc` принимает диапазон и подгоняет сам.
- `power.limit`, `memory.used`, `clocks.max.memory` тоже `N/A` — unified memory,
  отдельного VRAM-счётчика нет. Память смотреть через `free`.
- Под капом 2100 фактическая частота держится **2080–2086 MHz**,
  `clocks_event_reasons.active = 0x0` → троттлинга нет, упирается именно в кап.

### CPU: гетерогенные ядра

| Кластер | Ядер | max | min |
|---|---|---|---|
| Производительный (Cortex-X925) | 10 | **3900 MHz** | 1378 MHz |
| Энергоэффективный (Cortex-A725) | 10 | **2808 MHz** | 338 MHz |

- Драйвер `cppc_cpufreq`, `scaling_max_freq` доступен на запись руту →
  **кап CPU возможен** (например 3500 MHz режет только большой кластер).
- Governor сейчас **`performance`** — держит все 20 ядер на максимуме постоянно,
  включая простой. При наблюдаемых 86°C на CPU это заметный вклад в нагрев.
- Доступны: `conservative ondemand userspace powersave performance schedutil`.

### Термика

- 7 зон `/sys/class/thermal/thermal_zone*`, **все безымянные `acpitz`** —
  какая из них что, определить нельзя. Скрипт берёт максимум по всем.
- `lm-sensors` на хосте **нет** (и ставить нельзя — см. `CLAUDE.md`).
- hwmon: `hwmon0=acpitz`, `hwmon1=nvme`, `hwmon2=mt7925_phy0`.
- Под нагрузкой: **CPU 85–87°C при GPU 73–81°C** — процессорная часть SoC
  греется сильнее графической.

### NVMe — не проблема

| | °C |
|---|---|
| Composite (`temp1`) | 61.8 |
| Sensor 1 (контроллер) | 67.8 |
| Sensor 2 (NAND) | 61.8 |
| Порог троттлинга (`temp1_max`) | **82.85** |
| Критический (`temp1_crit`) | **84.85** |
| `temp1_alarm` | 0 (не сработал) |

Запас до троттлинга ~21°C. 61°C для плотного M.2 в компактном корпусе — норма.
Насторожиться стоит от устойчивых 75°C+ по композиту.

---

## 2. Зависания: что нашлось в логах

**За ~3.5 часа вечера 24.08 → ночи 25.08 система жёстко зависла четыре раза.**
Все четыре загрузки обрываются на полуслове, без единого признака корректного
выключения (нет `Reached target Shutdown`, нет `System is powering down` —
журнал просто кончается посреди рутинной записи).

| Загрузка | Начало | Обрыв | Длительность |
|---|---|---|---|
| -4 | 24.08 21:57:42 | 24.08 **23:15:01** | 1 ч 17 мин |
| -3 | 24.08 23:42:25 | 24.08 **23:49:55** | 7 мин |
| -2 | 24.08 23:50:34 | 25.08 **00:25:01** | 34 мин |
| -1 | 25.08 00:40:24 | 25.08 **01:02:56** | 22 мин |

### Загрузка -3: GPU не поднялся вообще

```
NVRM: ksec2PrepareBootCommands_GB20B: SEC2 secure boot partition timed out.
NVRM: ksec2PrepareBootCommands_GB20B: Preparing SEC2 boot cmds failed. RM cannot boot.
NVRM: nvCheckOkFailedNoLog: Check failed: Call timed out [NV_ERR_TIMEOUT] (0x00000065)
      returned from ksec2PrepareBootCommands_HAL(...) @ kernel_gsp_gh100.c:806
NVRM: GPU 000f:01:00.0: RmInitAdapter failed! (0x62:0x65:2028)
NVRM: GPU 000f:01:00.0: rm_init_adapter failed, device minor number 0
```

Типично **после** жёсткого зависания: GPU остаётся в неисправном состоянии, и
обычная перезагрузка его не чинит — нужно полное обесточивание.

### Чего в логах НЕТ (и это диагностично)

- ни одного `Xid`
- ни `MCE` / `machine check` / ошибок `EDAC`
- ни `thermal trip` / `critical temp` / `thermal shutdown`
- ни `hung task` / `soft lockup` / `hard lockup` / `watchdog: BUG`

→ Ядро **не успело ничего записать**: умерло мгновенно. Это профиль
**аппаратного локапа** (питание / SoC / память), а не штатной термозащиты.
Если бы система выключалась по перегреву, в журнале остался бы след.

### Ключевое: swap был включён не во всех падениях

В `/etc/fstab` прописан `/swap.img none swap sw 0 0` — **16 GB swapfile, который
поднимается заново при каждой загрузке**. `spark-helper.sh` его гасит, но только на
текущую сессию.

Сопоставление по журналу, запускался ли `spark-helper.sh` (по записям sudo):

| Загрузка | swap | Зависание |
|---|---|---|
| -4 | ON 21:57 → **swapoff в 22:19** | завис в **23:15** — через 56 мин после swapoff |
| -3 | swapoff выполнен | GPU не поднялся (см. выше), обрыв 23:49 |
| -2 | **ON всё время** | завис 00:25 |
| -1 | **ON всё время** | завис 01:02 |
| 0 | swapoff + `-lgc 300,2100` | работает |

**Вывод: выключение swap само по себе зависание не предотвратило.** В загрузке -4 машина
умерла через час после `swapoff -a`, с ComfyUI в docker (контейнер `comfyui` поднимался
во всех упавших загрузках). Это ослабляет гипотезу «чистый OOM-thrash в unified memory»
и усиливает аппаратную.

### Ложные следы, которые можно игнорировать

- Трейсы `do_idle+0x108/0x120 → cpu_startup_entry → secondary_start_kernel` в
  начале загрузок -1, -2, -4 — их порождает запуск `nvidia-bug-report`
  (`Comm: nvidia-bug-repo`), это безобидное предупреждение, не причина падений.
- `Shutting down` в grep'е — это `geoclue` и `gnome-shell`, а не systemd.

---

## 3. Что сделано со `spark-helper.sh`

Скрипт трогает **хост**, а не контейнер (`sudo swapoff`, режим драйвера,
частоты) — запускается вручную, агентом не запускается.

- Включён кап частот GPU: `300–2100 MHz` (был закомментирован).
- Добавлен полноценный CLI (`--help`), всё дублируется env-переменными
  `SPARK_GPU_MAX`, `SPARK_CPU_MAX`, `SPARK_GOVERNOR`, `SPARK_INTERVAL`, `SPARK_LOG`.
- Частоты принимаются **в двух форматах**: абсолютно (`2100`) и в процентах от
  аппаратного максимума (`70%`, читается из `nvidia-smi` на лету). Голое число
  меньше 100 отвергается с подсказкой — чтобы `70` не превратилось в 70 MHz.
- Добавлен **кап CPU** (`--cpu-max`): проход по всем ядрам, режутся только те,
  чей собственный максимум выше запрошенного.
- Добавлен `--governor`, `--keep-swap`, `--interval`, `--log`, `--no-monitor`.
- Добавлен `--reset`: сток частот GPU и CPU + `swapon -a`.
- Мониторинг расширен: частота GPU, утилизация, pstate, причины троттлинга,
  температура и частота CPU, load average, температура NVMe.
- GPU-метрики берутся **одним** вызовом `nvidia-smi` вместо двух — раньше
  temp и power были из разных моментов времени.
- **В лог пишется полная дата**, а не только `HH:MM:SS`. Именно из-за её
  отсутствия старый `thermal_monitor.log` было невозможно сопоставить с
  падениями. При старте в лог идёт маркер `### monitor started ...`,
  так что обрыв мониторинга виден как дырка.

```bash
./spark-helper.sh                                      # GPU 300-2100, монитор
./spark-helper.sh --gpu-max 70%                        # процент от 3003 MHz
./spark-helper.sh --gpu-max 2100 --cpu-max 3500 --governor schedutil
./spark-helper.sh --gpu-max off --no-monitor
./spark-helper.sh --reset                              # всё в сток
```

`thermal_monitor.log` в `.gitignore`, ротации нет — рос до 5.4 MB, чистить руками.

---

## 4. Что ещё не проверено

Отложено, чтобы не трогать работающую машину. Требует sudo:

```bash
sudo dmesg -T | tail -50                       # следы последнего локапа
ls -la /sys/fs/pstore/                         # там может лежать паника (Permission denied без sudo)
sudo nvme smart-log /dev/nvme0 | grep -iE "warning_temp_time|critical_comp_time|percentage_used"
```

`warning_temp_time` / `critical_comp_time` — минуты за порогами за всю жизнь
диска. Нули = диск ни разу не троттлил.

### Гипотезы по зависаниям, в порядке правдоподобия

1. **Аппаратный локап SoC под нагрузкой** — согласуется с полным отсутствием
   следов в журнале. Кандидаты: питание, unified memory, ранняя ревизия BIOS.
2. **Тепловой вклад governor `performance`** — 20 ядер на максимуме 24/7 при
   86°C. Не объясняет мгновенность смерти, но повышает базовую температуру.
3. **Штатные частоты GPU** — до сегодняшнего дня кап был выключен, GPU boost'ил
   до 2418 MHz. Теперь 2100.

Следующий шаг при повторе: собрать `thermal_monitor.log` **с датами** за период
до зависания и посмотреть, растут ли температуры и появляется ли `THROTTLE:0x...`
перед обрывом.

---

## 5. Что известно по форумам NVIDIA (поиск 2026-08-25)

Короткий ответ: **да, у DGX Spark есть задокументированный брак**, и он массовый.
Проблемы делятся на два независимых класса — аппаратный и архитектурный.

### 5.1. Аппаратный брак: питание / термодатчик → RMA

Главный тред-совпадение:
[2× DGX Spark FE: silent hard-locks under sustained inference — units RMA'd in 48h](https://forums.developer.nvidia.com/t/2x-dgx-spark-fe-silent-hard-locks-under-sustained-inference-units-rmad-in-48h-full-diagnosis-and-process-notes/380238)

Симптом описан дословно как наш:

> unreachable on all interfaces … **no panic, no OOM, no NVRM error, no shutdown record**

То есть отсутствие любых следов в журнале — это не «мы плохо искали», а **сама сигнатура
неисправности**. Совпадает с разделом 2 этого документа один в один.

Диагностика, которая ловит дефект — `dgx-spark-fieldiag`, тест **PowerStress**:

```
MODS-020000600139
"Acceptable temperature limits exceeded or the thermal sensor is broken or miscalibrated"
```

Один из двух юнитов в том треде **завис прямо во время PowerStress без загруженной ОС** —
это исключает софт как причину. Обе машины ушли по RMA, одобрение за ~48 часов.

Тот же код `MODS-020000600139` фигурирует ещё минимум в пяти независимых тредах
([1](https://forums.developer.nvidia.com/t/dgx-spark-fielddiag-powerstress-fail-mods-020000600139-thermal-sensor-requesting-rma/373266),
[2](https://forums.developer.nvidia.com/t/dgx-spark-fieldiag-powerstress-fail-mods-020000600139-rma-approved-requesting-advance-replacement/372145),
[3](https://forums.developer.nvidia.com/t/dgx-spark-failing-fieldiag-powerstress/373342),
[4](https://forums.developer.nvidia.com/t/dgx-spark-shutting-down-under-load-mods-020000600139/372469),
[5](https://forums.developer.nvidia.com/t/dgx-spark-unexpected-hard-reset-gpu-pcie-gen1-x1-root-port-width-x0-mlx5-insufficient-power-fielddiag-mods-020000600139/368572)).
В треде [DGX Spark freezes under load](https://forums.developer.nvidia.com/t/dgx-spark-freezes-under-load/374413)
сотрудник NVIDIA подтвердил, что провал PowerStress **сам по себе является основанием для RMA**,
и что проблема с подсистемой питания известна и затрагивает много юнитов с момента запуска.

Отдельный тред про датчики:
[partnerdiag PowerStress reproducibly hard-powers-off the box — acpitz 88→97.8 °C in 5s](https://forums.developer.nvidia.com/t/dgx-spark-gb10-partnerdiag-powerstress-reproducibly-hard-powers-off-the-box-acpitz-88-97-8-c-in-5s-all-other-field-tests-pass/377365).
Там зоны `acpitz` **меняются значениями местами** без изменения нагрузки
(`zone2 ↓81.4→65.6`, `zone4 ↑68.0→81.4` за 3 секунды) — то есть врут не температуры, а
маппинг/калибровка датчиков. Тоже RMA.

Есть и третий вариант брака, не наш: дефект PD-контроллера, при котором система
намертво зажата на ~30 W и не лечится перепрошивкой.

### 5.2. Архитектурный дефект: UMA OOM кладёт всю машину

Тред [Spark `hangs` — requires a hard-reset](https://forums.developer.nvidia.com/t/spark-hangs-requires-a-hard-reset-physically-unplugging/358951).
NVIDIA признала официально:

> This is a known issue which we are actively working to fix.
> The next major Spark OS release should have better handling of OOM.

Механизм: у GB10 CPU и GPU делят один физический пул памяти, поэтому при OOM
**голодает само ядро — раньше, чем успевает отработать OOM killer**. На дискретной H100
OOM изолирован в CUDA-контексте, здесь — нет. Рекомендации из треда: выключать swap
(чтобы процесс падал чисто, а не уводил систему в thrashing), ставить `earlyoom`,
иметь удалённый способ передёрнуть питание.

Смежное: [freezing из-за насыщения дискового кэша](https://forums.developer.nvidia.com/t/fixed-dgx-spark-freezing-and-lockup-issue-unable-to-load-new-models-due-to-cache-saturation/373483)
— лечится cron-скриптом с `sync; echo 3 > /proc/sys/vm/drop_caches` при кэше >40 GB.
**У нас это не наш случай:** `buff/cache` всего 7.7 GiB.

### 5.3. Конкретно ComfyUI на GB10

[Comfy-Org/ComfyUI#11106](https://github.com/Comfy-Org/ComfyUI/issues/11106) —
«System OOM & Crash on DGX (GB10/Blackwell) with CUDA 13.0 / PyTorch 2.9».

Причина — стечение трёх факторов:

1. `cudaMallocAsync` — аллокатор по умолчанию на GB10;
2. ComfyUI пинит **~90 % доступной RAM** (в отчёте ~116 GB) до начала работы;
3. CPU-bound ноды плодят треды на 20-ядерном CPU.

Триггеры: **VAE Decode (Z-Image)** и **любые препроцессоры глубины** (DepthAnything) —
мгновенный скачок RAM за 128 GB и паника ядра. Qwen Image / трансформер отрабатывают нормально.

- `--cpu-vae` спасает VAE Decode ценой производительности.
- Для depth-нод обхода нет.
- Отключить `cudaMallocAsync` не выходит — PyTorch падает на внутреннем ассерте,
  аллокатор фактически захардкожен под эту архитектуру.
- На момент отчёта (04.12.2025) **не исправлено**.

### 5.4. Наши цифры против цифр из RMA-треда

| | RMA-юниты (тред 380238) | Наша машина |
|---|---|---|
| Следы в журнале при зависании | нет вообще | **нет вообще** |
| `acpitz` под нагрузкой | 92–98 °C | **85–87 °C** |
| GPU под нагрузкой | 88–90 °C | 73–81 °C |
| Critical trip | 104 °C | **104 °C** |
| EC firmware | `0x03000508` (не помогла) | **`0x03000508`** |
| Троттлинг | `HW_THERMAL_SLOWDOWN` на 2197/3003 | не наблюдался (`0x0`) |

Сигнатура зависания совпадает точно, температуры при этом **ниже**, чем у отбракованных
юнитов, и аппаратного троттлинга мы не ловили. Так что однозначного вывода «брак» из
одних наших наблюдений не следует — нужен PowerStress.

**Важное совпадение:** в том же RMA-треде как временные меры рекомендованы ровно те две,
что мы сегодня и внедрили:

- кап GPU **2100 MHz** — убирает термотроттлинг, цена −21 % decode / −7 % prefill на 32K;
- кап CPU — у них 2400 MHz дал **92 °C → 84 °C при нулевой потере производительности**,
  потому что воркеры всё равно busy-poll'ят на 200–350 % CPU.

То есть выбранный нами профиль — это признанный форумом обходной путь для **этого самого**
класса отказов.

### 5.5. Что делать дальше

1. **Погонять на текущем профиле** (GPU 2100 + кап CPU + `schedutil`) и смотреть, уйдут ли
   зависания. Лог теперь с датами — будет с чем сопоставлять.
2. Если зависания останутся — **запустить Field Diagnostics**. Это и есть решающий тест
   «брак или нет», и он же нужен для RMA:
   ```bash
   sudo apt install dgx-spark-fieldiag        # из NVIDIA CUDA APT repo
   sudo init 3                                # Secure Boot должен быть выключен
   cd /opt/nvidia/dgx-spark-fieldiag
   sudo ./partnerdiag --field
   ```
   Сейчас **не установлен** (в `/opt/nvidia/` его нет). Гонять только на стоковых
   частотах — сначала `./spark-helper.sh --reset`, иначе результат невалиден для RMA.
   [Официальный гайд](https://docs.nvidia.com/pdf/userguide-dgx-spark-fieldiag.pdf) ·
   [страница NVIDIA](https://nvidia.custhelp.com/app/answers/detail/a_id/5767/~/nvidia-dgx-spark-field-diagnostics)
3. При провале PowerStress — тикет на nvidia.custhelp.com с логами fieldiag и кодом ошибки.
   По форуму одобрение занимает ~48 часов; замена может быть refurbished, advance shipping
   обычно не дают.
4. Параллельно, по линии ComfyUI: избегать Z-Image VAE Decode и depth-препроцессоров,
   либо пробовать `--cpu-vae`.

**Не проверено:** гипотеза «дело в термопасте» — в треде 380238 один из участников писал,
что переклейка помогла (заводская «clearly gone bad»), другому помогла чистка решёток от
пыли. Вскрытие может повлиять на гарантию — до RMA не трогать.

---

## 6. Источники — ссылки на форум

Собрано 2026-08-25. Сгруппировано по темам; звёздочкой отмечены самые близкие к нашему случаю.

### Зависания без следов в логах / RMA

- ★ [2× DGX Spark FE: silent hard-locks under sustained inference — units RMA'd in 48h. Full diagnosis and process notes](https://forums.developer.nvidia.com/t/2x-dgx-spark-fe-silent-hard-locks-under-sustained-inference-units-rmad-in-48h-full-diagnosis-and-process-notes/380238) — **главный тред**: симптом «no panic, no OOM, no NVRM error, no shutdown record», диагностика, процесс RMA, обходные меры (кап GPU 2100 / кап CPU 2400)
- ★ [DGX Spark freezes under load](https://forums.developer.nvidia.com/t/dgx-spark-freezes-under-load/374413) — сотрудник NVIDIA подтверждает, что провал PowerStress = основание для RMA; проблема питания известна и массовая
- ★ [Spark `hangs` — requires a hard-reset (physically unplugging)](https://forums.developer.nvidia.com/t/spark-hangs-requires-a-hard-reset-physically-unplugging/358951) — официальное признание NVIDIA про OOM в unified memory
- [NVIDIA DGX Spark continuously freezing, hanging, and or rebooting](https://forums.developer.nvidia.com/t/nvidia-dgx-spark-continuously-freezing-hanging-and-or-rebooting/365609)
- [My DGX Spark Hangs … is this normal?](https://forums.developer.nvidia.com/t/my-dgx-spark-hangs-frozen-completely/365930)
- [DGX Spark — Persistent 30-Minute Restart After ALL Firmware Updates](https://forums.developer.nvidia.com/t/dgx-spark-persistent-30-minute-restart-after-all-firmware-updates/364312)

### Термодатчики и PowerStress (код MODS-020000600139)

- ★ [partnerdiag PowerStress reproducibly hard-powers-off the box — acpitz 88→97.8 °C in 5s, all other field tests pass](https://forums.developer.nvidia.com/t/dgx-spark-gb10-partnerdiag-powerstress-reproducibly-hard-powers-off-the-box-acpitz-88-97-8-c-in-5s-all-other-field-tests-pass/377365) — зоны `acpitz` меняются значениями местами, дефект калибровки
- [DGX Spark — FieldDiag PowerStress FAIL (MODS-020000600139), thermal sensor — requesting RMA](https://forums.developer.nvidia.com/t/dgx-spark-fielddiag-powerstress-fail-mods-020000600139-thermal-sensor-requesting-rma/373266)
- [DGX Spark fieldiag PowerStress FAIL — MODS 020000600139 — RMA approved, requesting advance replacement](https://forums.developer.nvidia.com/t/dgx-spark-fieldiag-powerstress-fail-mods-020000600139-rma-approved-requesting-advance-replacement/372145)
- [Dgx spark failing fieldiag PowerStress](https://forums.developer.nvidia.com/t/dgx-spark-failing-fieldiag-powerstress/373342)
- [DGX Spark shutting down under load — MODS-020000600139](https://forums.developer.nvidia.com/t/dgx-spark-shutting-down-under-load-mods-020000600139/372469)
- [DGX Spark unexpected hard reset + GPU PCIe Gen1 x1 / root port Width x0 + mlx5 insufficient power + FieldDiag MODS-020000600139](https://forums.developer.nvidia.com/t/dgx-spark-unexpected-hard-reset-gpu-pcie-gen1-x1-root-port-width-x0-mlx5-insufficient-power-fielddiag-mods-020000600139/368572)

### Память, OOM, кэш

- [[Fixed] DGX Spark freezing and lockup issue; unable to load new models due to cache saturation](https://forums.developer.nvidia.com/t/fixed-dgx-spark-freezing-and-lockup-issue-unable-to-load-new-models-due-to-cache-saturation/373483) — фикс через `drop_caches` при кэше >40 GB (не наш случай: у нас кэш 7.7 GiB)
- [Gemma 4 on DGX Spark (GB10): System Freeze at >80% Utilization & sm_121 Kernel Issues](https://forums.developer.nvidia.com/t/gemma-4-on-dgx-spark-gb10-system-freeze-at-80-utilization-sm-121-kernel-issues/366060) — хардлок при попытке KV-кэша выйти за ~80 GB
- [My DGX Spark keeps freezing and crashing when I try to run this code no matter the LLM](https://forums.developer.nvidia.com/t/my-dgx-spark-keeps-freezing-and-crashing-when-i-try-to-run-this-code-no-matter-the-llm/353345)

### ComfyUI на GB10

- ★ [Comfy-Org/ComfyUI#11106 — System OOM & Crash on NVIDIA DGX (GB10/Blackwell) with CUDA 13.0 / PyTorch 2.9: "Depth" and "VAE Decode" trigger 128GB+ RAM spike](https://github.com/Comfy-Org/ComfyUI/issues/11106) — **прямо про наш стек**

### Гарантия и брак

- [Warranty Claim — DGX Spark Unit Defective](https://forums.developer.nvidia.com/t/warranty-claim-dgx-spark-unit-defective/361657)
- [DGX Spark RMA](https://forums.developer.nvidia.com/t/dgx-spark-rma/371310)
- [Unable to proceed with system recovery](https://forums.developer.nvidia.com/t/unable-to-proceed-with-system-recovery/350352)
- [Early Reports Indicate Nvidia DGX Spark May Be Suffering From Thermal Issues (Slashdot)](https://hardware.slashdot.org/story/25/10/29/035247/early-reports-indicate-nvidia-dgx-spark-may-be-suffering-from-thermal-issues) — обзор: троттлинг на 100 W вместо заявленных 240 W, спонтанные перезагрузки

### Документация и инструменты

- [NVIDIA DGX Spark Field Diagnostics User Guide (PDF)](https://docs.nvidia.com/pdf/userguide-dgx-spark-fieldiag.pdf)
- [NVIDIA DGX Spark Field Diagnostics (страница поддержки)](https://nvidia.custhelp.com/app/answers/detail/a_id/5767/~/nvidia-dgx-spark-field-diagnostics)
- [spark-doctor — сторонний диагностический CLI для GB10](https://github.com/joeynyc/spark-doctor) — детектит power cap, давление UMA, термориски, несовпадения колёс CUDA 13/sm_121
- [DGX Spark: Overheating, 100W Power Cap, 30W Safety Mode — Complete Diagnostic Guide](https://ai-muninn.com/en/blog/dgx-spark-30w-power-safety-mode)

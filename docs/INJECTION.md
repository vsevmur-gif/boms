# Инжект miOS в Instagram IPA

miOS — это один Mach-O dylib (`miOS.dylib`, fat arm64+arm64e), целящий **только
`com.burbn.instagram`**. Чтобы устройство загрузило его при каждом запуске
Instagram, нужно:

1. добавить в главный бинарь Instagram команду загрузки
   `LC_LOAD_DYLIB → @executable_path/Frameworks/miOS.dylib`;
2. положить сам `miOS.dylib` в `Payload/Instagram.app/Frameworks/`;
3. снять старую подпись (`_CodeSignature/`, `embedded.mobileprovision`);
4. переподписать (ldid для TrollStore / jailbreak, твой Apple-сертификат для
   AltStore / Sideloadly, или они подпишут сами при установке).

Три способа это сделать: нажатие в CI, локально, или на устройстве.

## Способ 1 — одна кнопка в GitHub Actions

Самый простой — всё делает CI, тебе достаточно прямой ссылки на IPA.

1. Открой **Actions** → **Patch Instagram IPA** → **Run workflow**.
2. В поле `ipa_url` вставь прямую ссылку на твой Instagram IPA (dropbox,
   mega, файл с любого хостинга который отдаёт его напрямую, собственный
   S3-URL и т.д.).
3. Нажми **Run**. Через ~1 минуту внизу run-страницы появится артефакт
   **`Instagram-IPA-miOS`** — скачай и ставь (см. ниже).

Workflow сам:
- берёт последний зелёный `miOS.dylib` с ветки,
- качает твой IPA,
- вызывает `scripts/patch-ipa.sh`,
- подписывает dylib + бинарь через `ldid -S` (self-sign),
- отдаёт готовый `Instagram-miOS.ipa` как артефакт.

## Способ 2 — локально одной командой

```bash
scripts/patch-ipa.sh Instagram.ipa miOS.dylib Instagram-miOS.ipa
```

Что нужно на машине:
- `unzip`, `zip` (стандартно),
- [`insert_dylib`](https://github.com/tyilo/insert_dylib) или
  [Linux-порт](https://github.com/Jhonsonlaid/insert_dylib),
- [`ldid`](https://github.com/ProcursusTeam/ldid) (нужен только для self-sign;
  если ставишь через AltStore/Sideloadly — можно без него).

На macOS `insert_dylib` ставится из Homebrew (`brew install insert_dylib`) или
собирается из указанного репо. `ldid` на macOS тоже есть в Homebrew.

Что делает скрипт:
1. распаковывает IPA во временный каталог;
2. находит `Payload/*.app` и его главный бинарь (по `CFBundleExecutable` из
   `Info.plist`);
3. копирует `miOS.dylib` в `.app/Frameworks/`;
4. добавляет weak-load `@executable_path/Frameworks/miOS.dylib` через
   `insert_dylib --inplace --all-yes --weak`;
5. удаляет `_CodeSignature/` и `embedded.mobileprovision`;
6. (опционально) `ldid -S` на dylib и бинарь, с сохранением original
   entitlements главного бинаря;
7. упаковывает обратно в `.ipa`.

## Способ 3 — ручной рецепт (чтобы понимать что происходит)

```bash
# 1. Распаковать.
unzip Instagram.ipa -d ig/
EXE="ig/Payload/Instagram.app/Instagram"

# 2. Положить dylib.
mkdir -p ig/Payload/Instagram.app/Frameworks
cp miOS.dylib ig/Payload/Instagram.app/Frameworks/

# 3. Добавить LC_LOAD_DYLIB.
insert_dylib --inplace --all-yes --weak \
    @executable_path/Frameworks/miOS.dylib \
    "$EXE"

# 4. Снять старую подпись.
rm -rf ig/Payload/Instagram.app/_CodeSignature
rm -f  ig/Payload/Instagram.app/embedded.mobileprovision

# 5. Self-sign (пропусти если AltStore/Sideloadly сам подпишет).
ldid -S ig/Payload/Instagram.app/Frameworks/miOS.dylib
ldid -e "$EXE" >ent.plist 2>/dev/null && ldid -Sent.plist "$EXE" || ldid -S "$EXE"

# 6. Собрать обратно.
cd ig && zip -r ../Instagram-miOS.ipa Payload && cd ..
```

## Как установить пропатченный IPA на устройство

| Способ          | Нужен Apple-сертификат? | Нужен джейл? | Срок жизни |
|-----------------|-------------------------|--------------|------------|
| **TrollStore**  | нет                     | нет¹         | навсегда   |
| **AltStore**    | бесплатный Apple ID     | нет          | 7 дней²    |
| **Sideloadly**  | бесплатный Apple ID     | нет          | 7 дней²    |
| **Xcode + dev** | платный ($99/год)       | нет          | 1 год      |
| **Jailbreak**   | нет                     | да           | навсегда   |

¹ TrollStore работает на iOS 14.0–16.6.1 через `CoreTrust`-уязвимость; это не
джейлбрейк, но и не каждая прошивка.
² AltStore / Sideloadly с бесплатным Apple ID даёт провижн на 7 дней — потом
нужно пересобирать и пере-ставить (AltServer делает это автоматически в
локальной сети).

На устройстве:
- **TrollStore**: AirDrop IPA → "Open with TrollStore" → Install.
- **AltStore**: открой `.ipa` в AltStore на устройстве (или с Mac/PC через
  AltServer). AltStore сам подпишет и установит.
- **Sideloadly**: подключи iPhone к компьютеру, запусти Sideloadly, выбери IPA,
  введи Apple ID.

## Проверка что всё работает

После установки запусти Instagram. В правой части экрана должна появиться
круглая градиентная кнопка **miOS**. Тап → откроется шторка с 5 вкладками
(Containers / Spoof / Location / Proxy / ⚙︎). Если кнопки нет:

- проверь, что `miOS.dylib` реально лежит в `Payload/Instagram.app/Frameworks/`
  в установленной `.app` (TrollStore показывает содержимое пакета);
- проверь что в бинаре есть команда `LC_LOAD_DYLIB` на наш путь:
  `otool -L Payload/Instagram.app/Instagram | grep miOS`;
- если ставил через AltStore/Sideloadly — убедись что они не выкинули
  `Frameworks/miOS.dylib` при переподписи (иногда они аггрессивно чистят).

## App Attest on sideloaded IPAs (crash on registration)

A resigned / sideloaded IPA cannot produce a valid **App Attest**
(`DCAppAttestService`) attestation: App Attest is bound to the app's real
App Store signing identity and is validated by Apple's servers. When the app
calls App Attest (often on launch or during **account registration**), it fails
in the Secure Enclave and the app is terminated — this happens on a **plain
resigned IPA with no tweak**, so it is not caused by miOS.

miOS can neutralise it: enable **"Block DeviceCheck & App Attest"** in the
container's fingerprint. The tweak then reports App Attest / DeviceCheck as
*unsupported*, so the app takes its no-attestation path instead of crashing.

Caveats:
- This stops the crash and usually lets the app run and **log in**.
- A backend that *requires* a valid attestation specifically for **new-account
  registration** may still refuse — that check is server-side. The reliable
  paths are: register the account through the official App Store app (or web)
  and then use it in the container, or install miOS as the rootless `.deb` on a
  **jailbroken** device over the original App Store app (its genuine signature
  keeps App Attest working).

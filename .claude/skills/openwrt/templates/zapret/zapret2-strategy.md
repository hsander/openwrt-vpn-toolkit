# zapret2 — стратегии nfqws2

Справочник стратегий DPI-обхода для zapret2 (бинарь `nfqws2`, Lua-десинхронизация).
Применение и подбор — см. `runbooks/11-zapret2.md`. Стратегия живёт в строке
`NFQWS2_OPT="..."` файла `/opt/zapret2/config` (НЕ в uci).

## Дефолтная стратегия (рабочая, ship by default)

Подобрана на стенде test1 (DPI = SNI silent-drop), проверена на форвард-клиенте:
`youtube.com → 200`, стабильно ~0.3s.

```
--comment=Strategy__yt_tcpseg
--filter-tcp=80 --filter-l7=http <HOSTLIST> --payload=http_req
--lua-desync=multisplit:pos=method+2
--new --filter-tcp=443 --filter-l7=tls <HOSTLIST> --payload=tls_client_hello
--lua-desync=tcpseg:pos=0,1:ip_id=rnd:repeats=1
--new --filter-udp=443 --filter-l7=quic <HOSTLIST_NOAUTO> --payload=quic_initial
--lua-desync=fake:blob=fake_default_quic:repeats=6
```

Ключевой элемент — TLS-секция: `--lua-desync=tcpseg:pos=0,1:ip_id=rnd:repeats=1`.

## Кандидаты под другого провайдера

Если дефолт не сработал, blockcheck2 на test1 находил рабочими также (TLS 443):

| Десинк | Заметка |
|--------|---------|
| `--lua-desync=tcpseg:pos=0,1:ip_id=rnd:repeats=1` | дефолт, самый стабильный |
| `--lua-desync=multidisorder:pos=1,midsld` | классический split, без fake-пакетов |
| `--lua-desync=multidisorder:pos=midsld` | проще |
| `--lua-desync=multisplit:pos=midsld` | split по midsld |
| `--lua-desync=syndata` | очень лёгкий, работал автономно |
| `--in-range=-s1 --lua-desync=oob:urp=midsld` | OOB-вариант |
| fake+seqovl: `--lua-init=fake_default_tls=tls_mod(fake_default_tls,'rnd') ... --lua-desync=multidisorder:pos=midsld:seqovl=midsld-1:seqovl_pattern=fake_default_tls` | для DPI, который ловит обычный split |

> ⚠ blockcheck2 тестирует только router-local (OUTPUT) путь. Его "AVAILABLE" не
> гарантирует работу на форвард-клиенте — обязательно проверять curl'ом через
> реального клиента за роутером. Подробности и нюанс OUTPUT-vs-FORWARD — в runbook 11.

## Тип DPI и как его определить

Прежде чем подбирать — понять характер блокировки (на форвард-клиенте, zapret выключен):

- **SNI silent-drop** (как на test1): TCP до `:443` коннектится, ClientHello уходит,
  дальше тишина (curl таймаут, без RST). DNS чистый. → помогают split/tcpseg/disorder.
- **RST-инъекция**: соединение рвётся с reset сразу после ClientHello. → fake/badseq.
- **IP-block**: даже TCP-handshake не проходит (connection refused/timeout на SYN). →
  zapret не поможет, нужен VPN/прокси для этих IP.
- **QUIC-блок**: UDP/443 режется отдельно — обычно форсируют TCP (fake QUIC desync).

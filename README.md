# Eqemu_check_handin_modified
A **drop-in replacement** for EQEmu’s traditional `check_handin` helper that adds **safe, opt-in scaling**, robust stack handling, and exploit-resistant defaults — while preserving **legacy quest behavior by default**.

This plugin is designed for **4-slot trade windows + money** (classic / older clients).

---

## ✨ Features

### ✅ Legacy-safe by default
- Existing quests behave exactly as before
- No automatic item or coin scaling unless explicitly enabled

### ✅ Opt-in scaling
- **Item scaling** (`item_scale => 1`)
- **Coin scaling** (`coin_scale => <pp per set>`)

### ✅ Stack-safe
- Correctly counts stacked items using slot charges
- No more “stack counts as 1” bugs

### ✅ Exploit-resistant
- Safe defaults (`coin_scale` defaults to coins-only)
- Optional caps (`max_sets`)
- Optional strict trade enforcement (`strict_trade`)
- Engine-backed item return (no dupes)

### ✅ Clean debug output
- Green debug messages
- Toggle per script or globally

---

## 📦 Installation

1. Save the plugin file as:

```
quests/plugins/check_handin.pl
```

2. Restart **world + zone**, or run:
```
#reload quest
```

---

## 🔁 Return Values

`plugin::check_handin` supports scalar or list context:

```perl
my $ok = plugin::check_handin(...);
```

```perl
my ($ok, $sets) = plugin::check_handin(...);
```

| Case | ok | sets |
|----|----|------|
| Failure | 0 | 0 |
| Normal handin | 1 | 0 |
| Item scale success | 1 | N |
| Coin scale success | 1 | N |

---

## 🧪 Usage Examples

### 1️⃣ Legacy behavior (no scaling)
```perl
plugin::check_handin(\%itemcount,
    1353 => 1,
);
```

---

### 2️⃣ Item scaling (OPT-IN)
```perl
plugin::check_handin(\%itemcount,
    1353       => 1,
    item_scale => 1,
);
```

- Stack of 5 → `sets = 5`
- All consumed in one hand-in

---

### 3️⃣ Item scaling with cap
```perl
plugin::check_handin(\%itemcount,
    1353       => 1,
    item_scale => 1,
    max_sets   => 10,
);
```

---

### 4️⃣ Coin scale (coins ONLY, default)
```perl
plugin::check_handin(\%itemcount,
    coin_scale => 50,  # 50pp per set
);
```

✔ 50pp → sets=1  
✔ 100pp → sets=2  
❌ 50pp + item → rejected  

---

### 5️⃣ Item + coin scale (explicit allow)
```perl
plugin::check_handin(\%itemcount,
    1353       => 1,
    coin_scale => 50,
    no_items   => 0,   # REQUIRED
);
```

---

### 6️⃣ Strict trade (reject extras)
```perl
plugin::check_handin(\%itemcount,
    1353         => 1,
    item_scale   => 1,
    strict_trade => 1,
);
```

---

## ⚙️ Options Reference

| Option | Type | Default | Description |
|-----|----|----|----|
| `item_scale` | bool | off | Enable item scaling (opt-in) |
| `coin_scale` | int | — | Platinum per set |
| `no_items` | bool | 1 | Coins-only for coin_scale |
| `max_sets` | int | 10 | Safety cap when scaling |
| `min_sets` | int | 1 | Minimum sets required |
| `strict_trade` | bool | off | Reject extra items/coins |
| `debug` | bool | off | Enable green debug output |

---

## 🔐 Security Notes

- **Scaling is never automatic**
- **Coin scaling is coins-only unless explicitly overridden**
- `max_sets` prevents bulk abuse
- `strict_trade` blocks junk-item exploits
- Engine-backed returns prevent duplication bugs

These defaults were chosen specifically to avoid breaking legacy quests.

---

## 🛠️ Debugging

Enable per-script:
```perl
debug => 1
```

Look for green messages prefixed with:
```
[check_handin]
```

---

## ✅ Best Practices

- Always use `item_scale` explicitly
- Always cap rewards (`max_sets`) on currency/faction/flags
- Use `strict_trade` for high-value rewards
- Keep reward logic in NPC scripts (not in the plugin)

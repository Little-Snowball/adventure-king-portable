# 可开关无敌：game.swf 旗标补丁

`patch_invincible.py` 在 `dev/pets/patch_pets.py` 已经打好的 `game/game.swf` 上再加一步，让那批硬补丁随运行时旗标生效：旗标为真时保持无敌版行为，为假时逐字节回到原版规则。

## 旗标契约

游戏侧只读，读取固定为下面三条指令，不新增类、不新增 namespace：

```
getlocal0
getproperty QName(PackageNamespace(""),"akInvincible")
iffalse <整块注入的字节数>
```

`mainrole`（含 `mainrole1`/`mainrole2`）与 `petrole`（含 9 个形态子类）都是 sealed 类，**外部写入必须落在原型上**，写到实例上会在运行时抛 #1056（严格模式）或静默失败：

```
主类引用 = ApplicationDomain.currentDomain.getDefinition("roles.mainrole") as Class; // 或先取到任一角色实例的 constructor
主类.prototype.akInvincible = true;
petrole 同理
```

属性缺失时 `getproperty` 返回 `undefined`，`iffalse` 视其为假，因此未写入时就是关闭状态，符合「默认关闭」。

## 改了什么

| 位置 | 改动 | 字节 |
|---|---|---|
| `roles.mainrole.changState` | 注入块前加 3 条守卫 | +8 |
| `roles.pets.petrole.changState` | 注入块前加 3 条守卫 | +8 |
| 9 个宠物类的技能门禁 | `pushtrue + 5×nop` → `getlex thisCurMp; pushbyte <费用>; greaterequals` | 等长 6 字节 |
| 9 个宠物类的能量扣费 | `pushbyte 0` → `pushbyte -<费用>` | 等长 2 字节 |
| 常量池 | 尾部追加字符串 `akInvincible` 与 `QName(PackageNamespace(""),… )` | 计数 3249→3250、3914→3915 |

守卫偏移等于注入块长度（`mainrole` 52、`petrole` 53），旗标为假时直接落到原版第一条指令。插入点之后所有指令整体平移，AVM2 分支是相对偏移，方法内没有 exception handler，因此无需搬移分支表。

开无敌时注入块照常把当前值写回上限、把变化量置 0，于是还原后的门禁与扣费被同样的机制抵消；关无敌时守卫跳过整块，门禁与扣费按原版执行。

## 重建

```powershell
python dev/invincible/patch_invincible.py --ffdec D:/tools/ffdec/ffdec.jar --input game/game.swf --output patched-game.swf
```

输入必须是 `patch_pets.py` 打完的 `game.swf`。工具自带校验：重导出 14 个方法体与计划一致、守卫偏移、门禁与扣费按指令名复算、池计数与既有 multiname 不漂移。遇到已经打过本步的文件会报错退出，不会重复插入。

`--inspect` 只打印常量池结构，便于核对索引，不写文件。

## 已知风险

- `getproperty` 读到的是原型上的值，`mainrole.prototype` 一处写入即可覆盖两名玩家，`petrole.prototype` 覆盖全部宠物形态；逐实例写入无效（sealed）。
- 门禁还原成 `greaterequals` 后，低等级宠物的能量上限若低于技能费用，开启无敌时也会被门禁挡住。注入块只抵消扣费，不改变比较本身。按现有数值表核对，各形态在其所属等级段内能量上限都高于对应技能费用，正常玩法不会触发。
- 本步不检查战斗内其它无敌来源，例如宿主每帧补满战士数值的逻辑仍在宿主侧。

## 验收

写入侧（原型赋值与每帧补满）在宿主 `dev/swf/scripts/§4399load_fla§/MainTimeline.as` 的 `applyFlag()` 与 `topUpRole()`，本工具只负责读取侧的守卫。两端要一起测。

- 静态：工具自带校验，跑完会对 14 个目标方法体重新导出比对；另可对补丁前后全量 `script:pcodehex` 导出做 `diff -rq`，除 `mainrole`、`petrole` 与 9 个宠物类外必须逐字节一致。
- 动态：按 `dev/二开说明.md` 的「验收方法」跑一次，关键判据是 `guardtest offDamage=1 onDamage=0`（角色）与 `petguard off=1 on=0`（宠物）。
- 交付基线：`game/game.swf` 应保持 6707075 字节、SHA-256 `cdc56ea5cc7c0faf5c2a40933b0e426874784da8769ea473d8bef2fb365c15e6`。

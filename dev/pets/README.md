# 宠物补丁

开发构建使用 Python 3.11、JDK 17 或更新版本、JPEXS FFDec 26.5.0。对进入打包流程的 `game.swf` 副本运行以下命令，将输出用作游戏主体。

```powershell
python portable-dev/pets/patch_pets.py --ffdec D:/tools/ffdec/ffdec.jar --input game.swf --output game-pets.swf
```

输入可使用已应用连续施法改动的 SWF。保留原始输入，在最终包中将输出放到 `game/game.swf`。

- `roles.pets.petrole.changState()` 将 HP、MP 设为当前上限后，按零变化量更新原游戏状态栏。所有宠物形态共用该方法。命中硬直、击退和命中特效照常，主人死亡后的宠物清理仍由游戏处理。
- `roles.mainrole.changState()` 按实例类型对法师 `roles.mainrole2` 同步 HP、MP 至当前上限，涵盖受伤、技能耗蓝和装备改变上限。战士的生命与法力规则沿用原版。这两个行为直接由游戏主体提供，与启动器的 `Invincible` 调试开关无关。
- 九种宠物形态的技能取消了最低 MP 门槛。六种攻击型形态在发动技能时扣费，三种治疗型形态在治疗动作的收益帧扣费，补丁将这九条扣费改为 0。冷却、着地条件、目标选择和释放动画仍由原技能决定。
- `fightMain.bgPicOk()` 按 `role2Date.roleCurPet` 读取玩家二当前宠物，关卡预加载时可把该宠物素材加入列表。

补丁从 SWF 读取类与方法的精确索引，仅更新指定方法字节码。构建后重新打开输出 SWF，核验目标方法索引及指令，同时检查十个宠物类中其余方法的反汇编。

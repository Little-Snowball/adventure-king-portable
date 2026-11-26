package §4399load_fla§
{
   import flash.display.*;
   import flash.events.*;
   import flash.net.*;
   import flash.system.*;
   import flash.text.*;
   import flash.utils.getQualifiedClassName;

   [SWF(width="960", height="600", backgroundColor="#000000", frameRate="24")]
   public dynamic class MainTimeline extends MovieClip
   {
      public var 游戏进度:*;
      public var game_mc:MovieClip;
      public var xml_url:URLRequest;
      public var load_mc:MovieClip;
      public var bg_mc:SimpleButton;
      public var game_loader:Loader;
      public var game_url:URLRequest;
      public var 进度:*;
      public var xml_loader:URLLoader;

      private var invincible:Boolean = false;
      private var experiencePerLevel:int = 50;
      private var diagnostics:Boolean = false;
      private var ready:Boolean = false;
      private var started:Boolean = false;
      private var currentFight:*;
      private var configuredActor1:*;
      private var configuredActor2:*;
      private var saveHookAdded:Boolean = false;
      private var hackHookAdded:Boolean = false;
      private var toggleButton:Sprite;
      private var toggleOnArt:Loader;
      private var toggleOffArt:Loader;
      private var toggleArtFallback:Shape;
      private var toggleArtLoaded:int = 0;
      private var levelButton:Sprite;
      private var unlockButton:Sprite;
      // 会话级标记：只在本局隐藏已经用过的家园按钮，不写入存档；重启后两个按钮会重新出现，
      // 以免新存档或换档后永远失去这两个入口。
      private var maxLevelDone:Boolean = false;
      private var unlockAllDone:Boolean = false;
      private var confirmPanel:Sprite;
      private var hintBox:Sprite;
      private var hintFrames:int = 0;
      private var flagApplied:int = -1;
      private var flagProbeLogged:Boolean = false;

      private static const MAX_ROLE_LEVEL:int = 40;
      private static const MAX_PET_LEVEL:int = 30;
      private static const WARRIOR_GEAR:Array = [100,200,300,400,900];
      private static const MAGE_GEAR:Array = [500,600,700,800,900];
      private static const WARRIOR_PRO:Array = ["pAtt","pDef","mDef","hp","mp"];
      private static const MAGE_PRO:Array = ["mAtt","pDef","mDef","hp","mp"];
      private static const PET_IDS:Array = [10103,10203,10303];
      private static const PET_KEYS:Array = ["1","2","3"];
      private static const MAP_COUNT:int = 13;

      public function MainTimeline()
      {
         super();
         addFrameScript(0,this.frame1);
      }

      public function 保存进度(event:Event) : void
      {
         this.进度.保存(this.游戏进度.saveDate);
      }

      // 载入完成后直接进入游戏自己的主菜单，不再有任何自绘选单。
      private function enterGame() : void
      {
         if(!this.ready || this.started || this.game_loader.content == null) return;
         this.started = true;
         var game:* = this.game_loader.content;
         game.initAll();
         game.mainMenu.visible = true;
         this.load_mc.visible = false;
         this.bg_mc.visible = false;
         var gameClass:* = ApplicationDomain.currentDomain.getDefinition("Main") as Class;
         this.游戏进度 = gameClass.saveDealer;
         this.载入进度();
         this.startRuntimeHooks();
         if(this.diagnostics) trace("[AdventureKing] game entered");
      }

      // 游戏主类第 26 帧才执行 initGameBefore()，在那之前 initAll() 会因为显示对象还是空而抛 #2007。
      // 每帧重试直到就绪，再进游戏。
      private function tryEnterGame() : void
      {
         if(this.started || !this.ready) return;
         var game:* = this.game_loader == null ? null : this.game_loader.content;
         if(game == null) return;
         if(game.bigMapDealer == null || game.mainMenu == null || game.mainMenu.menu1 == null) return;
         try { this.enterGame(); }
         catch(error:Error) { trace("[AdventureKing] enter failed: " + error.message); }
      }

      private function startRuntimeHooks() : void
      {
         if(!this.saveHookAdded)
         {
            this.addEventListener(Event.ENTER_FRAME,this.保存进度);
            this.saveHookAdded = true;
         }
         if(!this.hackHookAdded)
         {
            this.addEventListener(Event.ENTER_FRAME,this.hack);
            this.hackHookAdded = true;
         }
      }

      private function centeredText(value:String, width:int, height:int, size:int, color:uint) : TextField
      {
         var format:TextFormat = new TextFormat("Microsoft YaHei",size,color);
         format.align = "center";
         var label:TextField = new TextField();
         label.defaultTextFormat = format;
         label.selectable = false;
         label.mouseEnabled = false;
         label.multiline = false;
         label.width = width;
         label.height = height;
         label.text = value;
         return label;
      }

      private function wrappedText(value:String, width:int, height:int, size:int, color:uint) : TextField
      {
         var format:TextFormat = new TextFormat("Microsoft YaHei",size,color);
         format.align = "left";
         format.leading = 5;
         var label:TextField = new TextField();
         label.defaultTextFormat = format;
         label.selectable = false;
         label.mouseEnabled = false;
         label.wordWrap = true;
         label.multiline = true;
         label.width = width;
         label.height = height;
         label.text = value;
         return label;
      }

      // 关卡内的「无敌」开关，宿主为 Main.upLayer，跨关卡常驻，与家园按钮同一槽位居中。
      // 本体是两张备好的贴图（352×90 缩到 176×45），外加一层透明命中区保证整块（含翅膀外的透明部分）可点。
      private function ensureToggle(game:*) : void
      {
         var host:* = game.upLayer;
         if(host == null) return;
         if(this.toggleButton == null)
         {
            var button:Sprite = new Sprite();
            button.buttonMode = true;
            button.tabEnabled = false;
            button.mouseChildren = false;

            var hit:Shape = new Shape();
            hit.graphics.beginFill(0x000000,0);
            hit.graphics.drawRect(0,0,176,45);
            hit.graphics.endFill();
            button.addChild(hit);

            this.toggleArtFallback = this.makeToggleFallback();
            button.addChild(this.toggleArtFallback);
            this.toggleOnArt = this.makeToggleArt("ui/wudi-on.png");
            button.addChild(this.toggleOnArt);
            this.toggleOffArt = this.makeToggleArt("ui/wudi-off.png");
            button.addChild(this.toggleOffArt);

            button.addEventListener(MouseEvent.CLICK,this.onToggleClick);
            this.toggleButton = button;
         }
         if(this.toggleButton.parent != host) host.addChild(this.toggleButton);
         this.toggleButton.x = 392;
         this.toggleButton.y = 551;
         this.toggleButton.visible = game.thisFight != null && int(game.gameLevel) >= 1;
         this.refreshToggleSkin();
      }

      // 贴图到位前先放一个深色圆角矩形兜底，避免首帧出现空白按钮。
      private function makeToggleFallback() : Shape
      {
         var shape:Shape = new Shape();
         shape.graphics.lineStyle(1.2,0x8FB3D9,0.9);
         shape.graphics.beginFill(0x101B28,0.82);
         shape.graphics.drawRoundRect(0,0,176,45,12,12);
         shape.graphics.endFill();
         return shape;
      }

      private function makeToggleArt(path:String) : Loader
      {
         var art:Loader = new Loader();
         art.x = 0;
         art.y = 0;
         art.visible = false;
         var self:* = this;
         art.contentLoaderInfo.addEventListener(Event.COMPLETE,function(event:Event):void
         {
            art.width = 176;
            art.height = 45;
            self.toggleArtLoaded = self.toggleArtLoaded + 1;
            if(self.toggleArtLoaded >= 2)
            {
               if(self.toggleArtFallback != null) self.toggleArtFallback.visible = false;
               trace("[AdventureKing] wudi art ready=" + self.toggleArtLoaded);
            }
            self.refreshToggleSkin();
         });
         art.contentLoaderInfo.addEventListener(IOErrorEvent.IO_ERROR,function(event:IOErrorEvent):void
         {
            trace("[AdventureKing] wudi art failed: " + event.text);
         });
         art.contentLoaderInfo.addEventListener(SecurityErrorEvent.SECURITY_ERROR,function(event:SecurityErrorEvent):void
         {
            trace("[AdventureKing] wudi art failed: " + event.text);
         });
         try { art.load(new URLRequest(path)); }
         catch(error:Error) { trace("[AdventureKing] wudi art failed: " + error.message); }
         return art;
      }

      private function refreshToggleSkin() : void
      {
         if(this.toggleOnArt != null) this.toggleOnArt.visible = this.invincible;
         if(this.toggleOffArt != null) this.toggleOffArt.visible = !this.invincible;
      }

      private function onToggleClick(event:MouseEvent) : void
      {
         event.stopPropagation();
         this.invincible = !this.invincible;
         this.refreshToggleSkin();
         this.applyFlag();
         if(this.invincible)
         {
            var game:* = this.game_loader == null ? null : this.game_loader.content;
            if(game != null) this.pokeFight(game,true);
         }
         if(this.diagnostics) trace("[AdventureKing] invincible=" + this.invincible);
      }

      // 家园（关卡 0）底部的「一键满级」与「解锁所有关卡」，宿主为当前关卡 fightMain.uiLoader。
      private function ensureLevelButton(game:*) : void
      {
         var fight:* = game.thisFight;
         var host:* = fight == null ? null : fight.uiLoader;
         if(host == null || int(game.gameLevel) != 0)
         {
            this.removeFromParent(this.levelButton);
            this.removeFromParent(this.unlockButton);
            return;
         }
         if(this.maxLevelDone) this.removeFromParent(this.levelButton);
         else
         {
            if(this.levelButton == null)
               this.levelButton = this.homeButton("一键满级",0xE6C98A,0x4A3A1E,0xFFE9A8,this.onLevelClick);
            this.mountHome(this.levelButton,host,310,552);
         }
         if(this.unlockAllDone) this.removeFromParent(this.unlockButton);
         else
         {
            if(this.unlockButton == null)
               this.unlockButton = this.homeButton("解锁所有关卡",0x9FD3B8,0x1E4A34,0xD8FFE9,this.onUnlockClick);
            this.mountHome(this.unlockButton,host,490,552);
         }
      }

      private function homeButton(value:String, lineColor:uint, fillColor:uint, textColor:uint,
                                 action:Function) : Sprite
      {
         var button:Sprite = new Sprite();
         button.graphics.lineStyle(1.2,lineColor,0.9);
         button.graphics.beginFill(fillColor,0.92);
         button.graphics.drawRoundRect(0,0,160,30,10,10);
         button.graphics.endFill();
         button.buttonMode = true;
         button.tabEnabled = false;
         button.mouseChildren = false;
         var label:TextField = this.centeredText(value,160,22,16,textColor);
         label.y = 5;
         button.addChild(label);
         button.addEventListener(MouseEvent.CLICK,action);
         return button;
      }

      private function mountHome(button:Sprite, host:*, x:Number, y:Number) : void
      {
         if(button == null) return;
         if(button.parent != host)
         {
            this.removeFromParent(button);
            host.addChild(button);
         }
         button.x = x;
         button.y = y;
      }

      private function removeFromParent(button:Sprite) : void
      {
         if(button != null && button.parent != null) button.parent.removeChild(button);
      }

      private function onLevelClick(event:MouseEvent) : void
      {
         event.stopPropagation();
         var game:* = this.game_loader == null ? null : this.game_loader.content;
         if(game == null) return;
         var self:* = this;
         this.showConfirm(game,"一键满级",
            "该操作不可逆，建议自己通关后再使用。\n确认后：所有角色与宠物升至满级，宠物一律回到休息状态，按职业发放全部最高品质装备（放入背包，请自行穿戴），宝石每种 99 颗。",
            function():void { self.applyMaxLevel(game); });
      }

      private function onUnlockClick(event:MouseEvent) : void
      {
         event.stopPropagation();
         var game:* = this.game_loader == null ? null : this.game_loader.content;
         if(game == null) return;
         var self:* = this;
         this.showConfirm(game,"解锁所有关卡",
            "该操作不可逆，建议自己逐关通关后再使用。\n确认后：直接把第 1–13 关标记为已通关，大图上的全部关卡按钮随即解锁。",
            function():void { self.unlockAllLevels(game); });
      }

      private function showConfirm(game:*, title:String, text:String, action:Function) : void
      {
         if(this.confirmPanel != null) return;
         var host:* = game.upLayer;
         if(host == null) return;
         var self:* = this;
         var panel:Sprite = new Sprite();
         panel.graphics.beginFill(0x000000,0.62);
         panel.graphics.drawRect(0,0,960,600);
         panel.graphics.endFill();
         var box:Sprite = new Sprite();
         box.graphics.lineStyle(2,0xC8B27A,1);
         box.graphics.beginFill(0x1A2430,0.99);
         box.graphics.drawRoundRect(0,0,460,196,18,18);
         box.graphics.endFill();
         box.x = 250;
         box.y = 202;
         panel.addChild(box);
         var titleText:TextField = this.centeredText(title,460,30,22,0xFFE9A8);
         titleText.y = 18;
         box.addChild(titleText);
         var body:TextField = this.wrappedText(text,420,92,16,0xE8EFF7);
         body.x = 20;
         body.y = 56;
         box.addChild(body);
         var ok:Sprite = this.dialogButton("确认",96,150,76,function():void { action(); });
         var cancel:Sprite = this.dialogButton("取消",246,150,76,function():void { self.closeConfirm(); });
         box.addChild(ok);
         box.addChild(cancel);
         host.addChild(panel);
         this.confirmPanel = panel;
      }

      private function dialogButton(value:String, left:int, top:int, width:int, action:Function) : Sprite
      {
         var button:Sprite = new Sprite();
         button.graphics.lineStyle(1.2,0xB9D2EA,0.9);
         button.graphics.beginFill(0x2D4A63,0.98);
         button.graphics.drawRoundRect(0,0,width,34,10,10);
         button.graphics.endFill();
         button.x = left;
         button.y = top;
         button.buttonMode = true;
         button.tabEnabled = false;
         button.mouseChildren = false;
         var label:TextField = this.centeredText(value,width,24,16,0xFFFFFF);
         label.y = 5;
         button.addChild(label);
         button.addEventListener(MouseEvent.CLICK,function(event:MouseEvent):void
         {
            event.stopPropagation();
            action();
         });
         return button;
      }

      private function closeConfirm() : void
      {
         if(this.confirmPanel == null) return;
         if(this.confirmPanel.parent != null) this.confirmPanel.parent.removeChild(this.confirmPanel);
         this.confirmPanel = null;
      }

      private function applyMaxLevel(game:*) : void
      {
         this.closeConfirm();
         var dealer:* = null;
         try
         {
            var gameClass:* = ApplicationDomain.currentDomain.getDefinition("Main") as Class;
            dealer = gameClass.saveDealer;
         }
         catch(error:Error)
         {
            this.showHint(game,"无法读取存档数据。");
            return;
         }
         if(dealer == null || dealer.tempDate == null) return;
         var players:int = int(game.playerNum);
         var modeData:* = players == 2 ? dealer.tempDate.twoPlayerDate : dealer.tempDate.onePlayerDate;
         if(modeData == null) modeData = dealer.tempDate.onePlayerDate;
         if(modeData == null) return;
         this.captureLiveBags(game,modeData,players);
         this.maxRole(modeData.role1Date);
         if(players == 2) this.maxRole(modeData.role2Date);
         this.retirePets(game,players);
         game.saveRoleDate(dealer.tempDate);
         this.syncFightData(game,dealer,players,true);
         this.showHint(game,"已满级。宠物已回到休息状态，装备与宝石已放入背包，请自行穿戴。");
         this.maxLevelDone = true;
         if(this.diagnostics) trace("[AdventureKing] max level applied players=" + players);
      }

      // 保持当前战斗实例与 saveRoleDate 深拷贝后的 tempDate 引用一致，避免后续穿戴装备或召唤宠物写到旧对象，
      // 并重建背包面板以同步 Knapsack.m_aPackage（其 updateEquip 会用 filter() 断开原数组引用）与物品计数。
      private function captureLiveBags(game:*, modeData:*, players:int) : void
      {
         var fight:* = game.thisFight;
         if(fight == null || modeData == null) return;
         if(modeData.role1Date != null && fight.role1Bag != null && fight.role1Bag.m_aPackage != null)
            modeData.role1Date.roleBag = fight.role1Bag.m_aPackage;
         if(players == 2 && modeData.role2Date != null && fight.role2Bag != null && fight.role2Bag.m_aPackage != null)
            modeData.role2Date.roleBag = fight.role2Bag.m_aPackage;
      }

      private function syncFightData(game:*, dealer:*, players:int, refreshAndRebuild:Boolean) : void
      {
         var fight:* = game.thisFight;
         if(fight == null || dealer == null || dealer.tempDate == null) return;
         var modeData:* = players == 2 ? dealer.tempDate.twoPlayerDate : dealer.tempDate.onePlayerDate;
         if(modeData == null) modeData = dealer.tempDate.onePlayerDate;
         if(modeData == null) return;
         fight.gameActorDate = modeData;
         this.rebindActor(fight.mainActor1,modeData.role1Date);
         if(players == 2) this.rebindActor(fight.mainActor2,modeData.role2Date);
         if(refreshAndRebuild) this.refreshFight(game);
         this.rebuildBag(fight,fight.mainActor1,1);
         if(players == 2) this.rebuildBag(fight,fight.mainActor2,2);
      }

      private function rebindActor(actor:*, roleData:*) : void
      {
         if(actor == null || roleData == null) return;
         actor.thisPro = roleData;
         if(actor.myPet != null && int(roleData.roleCurPet) >= 0 && roleData.rolePet != null)
         {
            var petData:* = roleData.rolePet[int(roleData.roleCurPet)];
            if(petData != null) actor.myPet.thisPro = petData;
         }
      }

      private function rebuildBag(fight:*, actor:*, slot:int) : void
      {
         if(fight == null || actor == null || actor.thisPro == null) return;
         var key:String = "role" + slot + "Bag";
         var oldBag:* = fight[key];
         var wasVisible:Boolean = oldBag != null && Boolean(oldBag.visible);
         if(oldBag != null)
         {
            oldBag.closeKnapsack();
            if(oldBag.parent != null) oldBag.parent.removeChild(oldBag);
         }
         var pro:* = actor.thisPro;
         fight.initBag(pro.roleName,pro.roleSex,pro.roleCareer,pro.roleLevel,
            actor.thisCurHp,actor.thisCurMp,actor.thisAllHp,actor.thisAllMp,
            pro.roleBag,pro.roleEquip,slot);
         if(wasVisible)
         {
            fight.openBag(pro.roleLevel,actor.thisCurHp,actor.thisCurMp,actor.thisAllHp,actor.thisAllMp,slot);
         }
      }

      // 数据侧的 roleCurPet 已经是 -1，这里让在场宠物同步退场，避免数据与场景不一致。
      private function retirePets(game:*, players:int) : void
      {
         var fight:* = game.thisFight;
         if(fight == null || int(game.gameLevel) != 0) return;
         if(fight.mainActor1 != null && fight.mainActor1.myPet != null) fight.mainActor1.myPet.delThis();
         if(players == 2 && fight.mainActor2 != null && fight.mainActor2.myPet != null)
            fight.mainActor2.myPet.delThis();
      }

      private function unlockAllLevels(game:*) : void
      {
         this.closeConfirm();
         var dealer:* = null;
         try
         {
            var gameClass:* = ApplicationDomain.currentDomain.getDefinition("Main") as Class;
            dealer = gameClass.saveDealer;
         }
         catch(error:Error)
         {
            this.showHint(game,"无法读取存档数据。");
            return;
         }
         if(dealer == null || dealer.tempDate == null) return;
         var players:int = int(game.playerNum);
         var modeData:* = players == 2 ? dealer.tempDate.twoPlayerDate : dealer.tempDate.onePlayerDate;
         if(modeData == null) modeData = dealer.tempDate.onePlayerDate;
         if(modeData == null) return;
         var maps:Array = [];
         var scores:Array = [];
         var stage:int = 0;
         while(stage < MAP_COUNT)
         {
            maps.push(String(stage + 1));
            // 通关判定是 scoreArray != 0，且历史合计被当作基线，所以用指数增长保证每关都非零。
            scores.push(100 << stage);
            stage++;
         }
         this.captureLiveBags(game,modeData,players);
         modeData.mapArray = maps;
         modeData.scoreArray = scores;
         game.saveRoleDate(dealer.tempDate);
         this.syncFightData(game,dealer,players,false);
         this.refreshBigMap(game,maps);
         this.showHint(game,"已把 1–13 关标记为通关，大图关卡按钮已解锁。");
         this.unlockAllDone = true;
         if(this.diagnostics) trace("[AdventureKing] unlock all levels players=" + players);
      }

      // initBigMap 会顺手把大图弹出来，调用前后要还原它原本的可见状态。
      private function refreshBigMap(game:*, maps:Array) : void
      {
         var dealer:* = game.bigMapDealer;
         if(dealer == null) return;
         var mapMc:* = dealer.bigMapMc;
         var wasVisible:Boolean = mapMc != null && Boolean(mapMc.visible);
         dealer.initBigMap(maps);
         if(mapMc != null) mapMc.visible = wasVisible;
      }

      private function maxRole(role:*) : void
      {
         if(role == null) return;
         role.roleLevel = MAX_ROLE_LEVEL;
         role.roleExp = 0;
         this.maxPets(role);
         this.maxBag(role);
      }

      // pk 是宠物品种键，同品种只保留一条记录：已有就原地升到三阶，没有才追加。
      // 满级后一律设为休息（roleCurPet = -1），出战与否交给玩家自己选。
      private function maxPets(role:*) : void
      {
         if(role.rolePet == null) role.rolePet = [];
         var pets:Array = role.rolePet as Array;
         var i:int = 0;
         while(i < pets.length)
         {
            if(pets[i] != null)
            {
               pets[i].lev = MAX_PET_LEVEL;
               pets[i].exp = 0;
            }
            i++;
         }
         i = 0;
         while(i < PET_IDS.length)
         {
            var key:String = PET_KEYS[i];
            var slot:int = -1;
            var j:int = 0;
            while(j < pets.length)
            {
               if(pets[j] != null && String(pets[j].pk) == key)
               {
                  slot = j;
                  break;
               }
               j++;
            }
            if(slot < 0)
            {
               pets.push({"id":PET_IDS[i],"lev":MAX_PET_LEVEL,"exp":0,"pk":key});
            }
            else
            {
               pets[slot].id = PET_IDS[i];
               pets[slot].lev = MAX_PET_LEVEL;
               pets[slot].exp = 0;
            }
            i++;
         }
         role.roleCurPet = -1;
      }

      private function maxBag(role:*) : void
      {
         if(role.roleBag == null) role.roleBag = [];
         var bag:Array = role.roleBag as Array;
         var warrior:Boolean = String(role.roleCareer) == "战士";
         var families:Array = warrior ? WARRIOR_GEAR : MAGE_GEAR;
         var affixes:Array = warrior ? WARRIOR_PRO : MAGE_PRO;
         var f:int = 0;
         while(f < families.length)
         {
            var tier:int = 1;
            while(tier <= 6)
            {
               var itemId:String = String(int(families[f]) + tier);
               var index:int = this.bagIndex(bag,itemId);
               if(index < 0)
               {
                  bag.push([itemId,5,affixes.slice(),1]);
               }
               else
               {
                  bag[index][1] = 5;
                  bag[index][2] = affixes.slice();
                  bag[index][3] = 1;
               }
               tier++;
            }
            f++;
         }
         var gem:int = 2001;
         while(gem <= 2005)
         {
            var gemId:String = String(gem);
            var gemIndex:int = this.bagIndex(bag,gemId);
            if(gemIndex < 0) bag.push([gemId,0,[],99]);
            else if(int(bag[gemIndex][3]) < 99) bag[gemIndex][3] = 99;
            gem++;
         }
      }

      private function bagIndex(bag:Array, itemId:String) : int
      {
         var i:int = 0;
         while(i < bag.length)
         {
            if(bag[i] != null && String(bag[i][0]) == itemId) return i;
            i++;
         }
         return -1;
      }

      private function refreshFight(game:*) : void
      {
         var fight:* = game.thisFight;
         if(fight == null) return;
         this.refreshRole(fight.mainActor1);
         if(int(game.playerNum) == 2) this.refreshRole(fight.mainActor2);
      }

      // 沿用官方 levelUp 的刷新序列：initMyPro -> 满值 -> changState -> 技能面板。
      private function refreshRole(role:*) : void
      {
         if(role == null || role.thisStateBoard == null || role.thisPro == null) return;
         role.initMyPro();
         role.thisCurHp = role.thisAllHp;
         role.thisCurMp = role.thisAllMp;
         role.changState(0,"hp");
         role.changState(0,"mp");
         role.changState(0,"exp");
         role.thisStateBoard.lvWard.text = String(MAX_ROLE_LEVEL);
         role.initSkillBoard();
         var pet:* = role.myPet;
         if(pet == null) return;
         if(pet.thisCurHp <= 0) return;
         pet.initMyPro(pet.thisPro);
         pet.thisCurHp = pet.thisAllHp;
         pet.thisCurMp = pet.thisAllMp;
         pet.changState(0,"hp");
         pet.changState(0,"mp");
         pet.changState(0,"exp");
         if(pet.thisStateBoard != null) pet.thisStateBoard.lvWard.text = String(MAX_PET_LEVEL);
      }

      // 原版在宠物休息/退场时不会移除状态条（唯一移除点是进化分支），这里按帧补收。
      // 只有"确定不出战"（myPet 为空且 roleCurPet 为 -1）时才清，避免误删进化中或死亡中的状态条。
      private function dropPetBoards(fight:*, actor:*) : void
      {
         if(actor == null || actor.thisPro == null) return;
         if(actor.myPet != null || int(actor.thisPro.roleCurPet) != -1) return;
         var want:String = int(actor.mySite) == 2 ? "petStaBoard2" : "petStaBoard1";
         var host:* = fight.uiLoader;
         if(host == null) return;
         for(var i:int = host.numChildren - 1; i >= 0; i--)
         {
            if(getQualifiedClassName(host.getChildAt(i)) == want) host.removeChildAt(i);
         }
      }

      private function showHint(game:*, value:String) : void
      {
         if(this.hintBox != null && this.hintBox.parent != null) this.hintBox.parent.removeChild(this.hintBox);
         var host:* = game.upLayer;
         if(host == null) return;
         var box:Sprite = new Sprite();
         box.graphics.beginFill(0x000000,0.68);
         box.graphics.drawRoundRect(0,0,660,30,8,8);
         box.graphics.endFill();
         box.x = 150;
         box.y = 512;
         var label:TextField = this.centeredText(value,660,22,16,0xFFE9A8);
         label.y = 5;
         box.addChild(label);
         host.addChild(box);
         this.hintBox = box;
         this.hintFrames = 0;
      }

      private function tickHint() : void
      {
         if(this.hintBox == null) return;
         this.hintFrames++;
         if(this.hintFrames > 110)
         {
            if(this.hintBox.parent != null) this.hintBox.parent.removeChild(this.hintBox);
            this.hintBox = null;
         }
      }

      private function perFrame(event:Event) : void
      {
         var game:* = this.game_loader == null ? null : this.game_loader.content;
         if(game == null) return;
         // 进游戏推迟到帧事件里做：在 Loader 的 complete 回调里跑 game.initAll() 会抛 #1009。
         if(!this.started) this.tryEnterGame();
         this.ensureToggle(game);
         this.ensureLevelButton(game);
         var fight:* = game.thisFight;
         if(fight != null)
         {
            this.dropPetBoards(fight,fight.mainActor1);
            if(int(game.playerNum) == 2) this.dropPetBoards(fight,fight.mainActor2);
         }
         this.tickHint();
      }

      public function hack(event:Event) : void
      {
         if(this.game_loader == null) return;
         var game:* = this.game_loader.content;
         if(game == null) return;
         var fight:* = game.thisFight;
         if(fight !== this.currentFight)
         {
            this.currentFight = fight;
            this.configuredActor1 = null;
            this.configuredActor2 = null;
            this.flagProbeLogged = false;
         }
         if(fight == null) return;
         this.applySettings(fight.mainActor1,1);
         if(game.playerNum == 2) this.applySettings(fight.mainActor2,2);
      }

      private function pokeFight(game:*, force:Boolean) : void
      {
         this.applyFlag();
         var fight:* = game.thisFight;
         if(fight == null) return;
         this.topUpRole(fight.mainActor1,force);
         if(int(game.playerNum) == 2) this.topUpRole(fight.mainActor2,force);
      }

      // mainrole 与 petrole 都是 sealed 类，逐实例赋值会抛 #1056。旗标改写到类原型：
      // 实例沿 [[Prototype]] 链读得到，且 mainrole1/2 与九个宠物形态自动继承。
      private function applyFlag() : void
      {
         var wanted:int = this.invincible ? 1 : 0;
         if(this.flagApplied == wanted) return;
         try
         {
            var mainClass:* = ApplicationDomain.currentDomain.getDefinition("roles.mainrole");
            var petClass:* = ApplicationDomain.currentDomain.getDefinition("roles.pets.petrole");
            mainClass.prototype.akInvincible = this.invincible;
            petClass.prototype.akInvincible = this.invincible;
            this.flagApplied = wanted;
            if(this.diagnostics)
               trace("[AdventureKing] flag=" + this.invincible
                  + " mainrole=" + mainClass.prototype.akInvincible
                  + " petrole=" + petClass.prototype.akInvincible);
         }
         catch(error:Error)
         {
            trace("[AdventureKing] flag write failed: " + error.message);
         }
      }

      private function topUpRole(role:*, force:Boolean) : void
      {
         if(role == null || role.thisStateBoard == null) return;
         if(force || role.thisAllHp > 0 && role.thisCurHp < role.thisAllHp)
         {
            if(role.thisAllHp > 0)
            {
               role.thisCurHp = role.thisAllHp;
               role.changState(0,"hp");
            }
         }
         if(force || role.thisAllMp > 0 && role.thisCurMp < role.thisAllMp)
         {
            if(role.thisAllMp > 0)
            {
               role.thisCurMp = role.thisAllMp;
               role.changState(0,"mp");
            }
         }
         var pet:* = role.myPet;
         if(pet == null) return;
         if(pet.thisCurHp <= 0) return;
         if(pet.thisStateBoard == null) return;
         if(force || pet.thisAllHp > 0 && pet.thisCurHp < pet.thisAllHp)
         {
            if(pet.thisAllHp > 0)
            {
               pet.thisCurHp = pet.thisAllHp;
               pet.changState(0,"hp");
            }
         }
         if(force || pet.thisAllMp > 0 && pet.thisCurMp < pet.thisAllMp)
         {
            if(pet.thisAllMp > 0)
            {
               pet.thisCurMp = pet.thisAllMp;
               pet.changState(0,"mp");
            }
         }
      }

      private function applySettings(actor:*, slot:int) : void
      {
         if(actor == null || actor.thisStateBoard == null || actor.thisPro == null) return;
         this.applyFlag();
         var pet:* = actor.myPet;
         if(this.invincible) this.topUpRole(actor,false);
         if(this.diagnostics && !this.flagProbeLogged)
         {
            this.flagProbeLogged = true;
            trace("[AdventureKing] probe actor=" + actor.akInvincible
               + " pet=" + (pet == null ? "none" : String(pet.akInvincible))
               + " invincible=" + this.invincible);
         }

         if(this.experiencePerLevel == 0) return;
         if(actor === (slot == 1 ? this.configuredActor1 : this.configuredActor2)) return;
         var levels:Array = actor.levelArr as Array;
         if(levels == null || levels.length == 0) return;
         for(var i:int = 0; i < levels.length; i++)
            levels[i] = this.experiencePerLevel;
         if(slot == 1) this.configuredActor1 = actor;
         else this.configuredActor2 = actor;
         actor.changState(0,"exp");
         if(actor.thisStateBoard.expBar.scaleX > 1)
            actor.thisStateBoard.expBar.scaleX = 1;
         if(this.diagnostics)
            trace("[AdventureKing] applied experiencePerLevel=" + this.experiencePerLevel + " player=" + slot);
      }

      internal function frame1() : void
      {
         stop();
         this.bg_mc.enabled = false;
         this.进度 = new 本地保存();
         this.readSettings();
         this.xml_url = new URLRequest("files.xml");
         this.game_url = new URLRequest();
         this.game_loader = new Loader();
         this.xml_loader = new URLLoader();
         this.xml_loader.addEventListener(Event.COMPLETE,this.load_game);
         this.xml_loader.addEventListener(IOErrorEvent.IO_ERROR,this.loadError);
         this.xml_loader.addEventListener(SecurityErrorEvent.SECURITY_ERROR,this.loadError);
         this.xml_loader.load(this.xml_url);
      }

      private function readSettings() : void
      {
         var parameters:Object = this.loaderInfo.parameters;
         if(parameters == null) return;
         this.diagnostics = this.readFlag(parameters.debug,false);
         var raw:String = String(parameters.experiencePerLevel);
         if(/^[0-9]+$/.test(raw))
         {
            var value:Number = Number(raw);
            if(value <= 1000000) this.experiencePerLevel = int(value);
         }
         if(this.diagnostics)
            trace("[AdventureKing] invincible=" + this.invincible + " experiencePerLevel=" + this.experiencePerLevel);
      }

      private function readFlag(raw:*, fallback:Boolean) : Boolean
      {
         var value:String = String(raw).toLowerCase();
         if(value == "true" || value == "1") return true;
         if(value == "false" || value == "0") return false;
         return fallback;
      }

      public function load_game(event:Event) : void
      {
         var files:XML;
         try { files = new XML(this.xml_loader.data); }
         catch(error:Error)
         {
            this.load_mc.loadFailed("Invalid files.xml");
            return;
         }
         var item:String = String(files.item);
         if(item == "")
         {
            this.load_mc.loadFailed("Missing game SWF in files.xml");
            return;
         }
         this.game_url.url = item;
         var context:LoaderContext = new LoaderContext();
         context.applicationDomain = ApplicationDomain.currentDomain;
         var info:LoaderInfo = this.game_loader.contentLoaderInfo;
         info.addEventListener(ProgressEvent.PROGRESS,this.load_mc.load_inf);
         info.addEventListener(Event.COMPLETE,this.onGameLoaded);
         info.addEventListener(IOErrorEvent.IO_ERROR,this.loadError);
         info.addEventListener(SecurityErrorEvent.SECURITY_ERROR,this.loadError);
         this.game_mc.addChild(this.game_loader);
         try { this.game_loader.load(this.game_url,context); }
         catch(error:Error) { this.load_mc.loadFailed(error.message); }
      }

      private function onGameLoaded(event:Event) : void
      {
         var info:LoaderInfo = LoaderInfo(event.currentTarget);
         info.removeEventListener(ProgressEvent.PROGRESS,this.load_mc.load_inf);
         info.removeEventListener(Event.COMPLETE,this.onGameLoaded);
         info.removeEventListener(IOErrorEvent.IO_ERROR,this.loadError);
         info.removeEventListener(SecurityErrorEvent.SECURITY_ERROR,this.loadError);
         this.ready = true;
         this.applyFlag();
         this.addEventListener(Event.ENTER_FRAME,this.perFrame);
         if(this.diagnostics) trace("[AdventureKing] game loaded");
      }

      private function loadError(event:ErrorEvent) : void
      {
         this.load_mc.loadFailed(event.text);
      }

      public function 载入进度() : void
      {
         var data:* = this.进度.读取();
         if(data)
         {
            this.游戏进度.saveDate = data;
            this.游戏进度.tempDate = data;
         }
      }
   }
}

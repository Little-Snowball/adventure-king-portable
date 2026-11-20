package §4399load_fla§
{
   import flash.display.*;
   import flash.events.*;
   import flash.net.*;
   import flash.system.*;
   import flash.text.*;
   import flash.ui.Keyboard;
   import flash.utils.ByteArray;

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

      private var invincible:Boolean = true;
      private var experiencePerLevel:int = 50;
      private var diagnostics:Boolean = false;
      private var ready:Boolean = false;
      private var started:Boolean = false;
      private var currentFight:*;
      private var configuredActor1:*;
      private var configuredActor2:*;
      private var startupMenu:Sprite;
      private var startupStatus:TextField;
      private var presetLoader:URLLoader;
      private var pendingPreset:String;
      private var presetStorage:SharedObject;

      private static const SINGLE:String = "single-mage";
      private static const DOUBLE:String = "double-mage";

      public function MainTimeline()
      {
         super();
         addFrameScript(0,this.frame1);
      }

      public function 保存进度(event:Event) : void
      {
         if(this.presetStorage != null)
            this.presetStorage.data.数据 = this.游戏进度.saveDate;
         else
            this.进度.保存(this.游戏进度.saveDate);
      }

      public function game_start(event:MouseEvent) : void
      {
         this.showStartupMenu();
      }

      private function startGame(players:int, newGame:Boolean, data:Object = null) : void
      {
         if(!this.ready || this.started || this.game_loader.content == null) return;
         this.started = true;
         var game:* = this.game_loader.content;
         game.initAll();
         game.mainMenu.visible = true;
         this.load_mc.visible = false;
         this.bg_mc.visible = false;
         if(this.startupMenu != null) this.removeChild(this.startupMenu);

         var gameClass:* = ApplicationDomain.currentDomain.getDefinition("Main") as Class;
         this.游戏进度 = gameClass.saveDealer;
         if(data != null) game.loadRoleDate(data);
         else this.载入进度();
         this.addEventListener(Event.ENTER_FRAME,this.保存进度);
         if(this.invincible || this.experiencePerLevel > 0)
            this.addEventListener(Event.ENTER_FRAME,this.hack);

         if(players != 0)
         {
            var menu:* = game.mainMenu;
            var modeButton:* = players == 1 ? menu.menu1.onePlayerBtn : menu.menu1.twoPlayerBtn;
            modeButton.dispatchEvent(new MouseEvent(MouseEvent.MOUSE_DOWN,false));
            var nextButton:* = newGame ? (menu.menu3.visible ? menu.menu3 : menu.menu2).newGameBtn : menu.menu3.continueBtn;
            nextButton.dispatchEvent(new MouseEvent(MouseEvent.MOUSE_DOWN,false));
         }
         if(this.diagnostics)
            trace("[AdventureKing] game started mode=" + players + " preset=" + this.pendingPreset);
      }

      private function showStartupMenu() : void
      {
         if(!this.ready || this.started || this.startupMenu != null) return;
         this.load_mc.visible = false;
         this.startupMenu = new Sprite();
         this.startupMenu.graphics.beginFill(0x101B28,0.98);
         this.startupMenu.graphics.drawRoundRect(0,0,430,372,24,24);
         this.startupMenu.graphics.endFill();
         this.startupMenu.x = 265;
         this.startupMenu.y = 114;
         this.addChild(this.startupMenu);
         this.startupMenu.addChild(this.menuText("选择游戏进度",24,20,382,36,26,0xF7F9FD));
         this.addMenuButton("新开游戏 · 单人",24,76,184,function():void { startGame(1,true); });
         this.addMenuButton("新开游戏 · 双人",222,76,184,function():void { startGame(2,true); });
         this.addMenuButton("打开存档一 · 单人满级法师",24,132,382,function():void { openPreset(SINGLE,1); });
         this.addMenuButton("打开存档二 · 双人满级法师",24,188,382,function():void { openPreset(DOUBLE,2); });
         this.addMenuButton("游戏主菜单 · 继续个人进度／设置",24,244,382,function():void { startGame(0,false); });
         this.startupStatus = this.menuText("两个预设的进度分别保存。",24,310,382,48,15,0xC7D5E4);
         this.startupMenu.addChild(this.startupStatus);
      }

      private function menuText(value:String, left:Number, top:Number, width:Number, height:Number,
                                size:int, color:uint) : TextField
      {
         var label:TextField = new TextField();
         label.defaultTextFormat = new TextFormat("Microsoft YaHei",size,color);
         label.x = left;
         label.y = top;
         label.width = width;
         label.height = height;
         label.text = value;
         label.selectable = false;
         label.mouseEnabled = false;
         label.wordWrap = true;
         return label;
      }

      private function addMenuButton(value:String, left:int, top:int, width:int, action:Function) : void
      {
         var button:Sprite = new Sprite();
         button.graphics.beginFill(0x2D4A63);
         button.graphics.drawRoundRect(0,0,width,44,12,12);
         button.graphics.endFill();
         button.x = left;
         button.y = top;
         button.buttonMode = true;
         button.tabEnabled = true;
         button.mouseChildren = false;
         button.addChild(this.menuText(value,12,8,width - 24,30,17,0xFFFFFF));
         button.addEventListener(MouseEvent.CLICK,function(event:MouseEvent):void
         {
            if(presetLoader == null) action();
         });
         button.addEventListener(KeyboardEvent.KEY_DOWN,function(event:KeyboardEvent):void
         {
            if(presetLoader == null && (event.keyCode == Keyboard.ENTER || event.keyCode == Keyboard.SPACE)) action();
         });
         button.addEventListener(MouseEvent.ROLL_OVER,function(event:MouseEvent):void { button.alpha = 0.82; });
         button.addEventListener(MouseEvent.ROLL_OUT,function(event:MouseEvent):void { button.alpha = 1; });
         this.startupMenu.addChild(button);
      }

      private function openPreset(name:String, players:int) : void
      {
         this.pendingPreset = name;
         var storage:SharedObject = SharedObject.getLocal("shengbingchuanqi-" + name);
         var modeKey:String = players == 1 ? "onePlayerDate" : "twoPlayerDate";
         if(storage.data.数据 != null && storage.data.数据.hasOwnProperty(modeKey))
         {
            this.presetStorage = storage;
            this.startGame(players,false,storage.data.数据);
            return;
         }
         this.startupStatus.text = "正在读取存档…";
         var reader:URLLoader = new URLLoader();
         reader.dataFormat = URLLoaderDataFormat.BINARY;
         this.presetLoader = reader;
         reader.addEventListener(Event.COMPLETE,function(event:Event):void
         {
            var data:Object;
            try
            {
               var bytes:ByteArray = ByteArray(reader.data);
               bytes.objectEncoding = ObjectEncoding.AMF3;
               data = bytes.readObject();
               if(data == null || !data.hasOwnProperty(modeKey) || data[modeKey] == null)
                  throw new Error("Missing save mode " + modeKey);
            }
            catch(error:Error)
            {
               presetFailed(error.message);
               return;
            }
            presetLoader = null;
            presetStorage = storage;
            startGame(players,false,data);
         });
         reader.addEventListener(IOErrorEvent.IO_ERROR,function(event:IOErrorEvent):void { presetFailed(event.text); });
         reader.addEventListener(SecurityErrorEvent.SECURITY_ERROR,function(event:SecurityErrorEvent):void { presetFailed(event.text); });
         try { reader.load(new URLRequest("presets/" + name + ".amf")); }
         catch(error:Error) { this.presetFailed(error.message); }
      }

      private function presetFailed(message:String) : void
      {
         this.presetLoader = null;
         this.startupStatus.text = "无法打开这份存档。请检查 game/presets 文件夹。";
         trace("[AdventureKing] preset " + this.pendingPreset + ": " + message);
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
         }
         if(fight == null) return;
         this.applySettings(fight.mainActor1,1);
         if(game.playerNum == 2) this.applySettings(fight.mainActor2,2);
      }

      private function applySettings(actor:*, slot:int) : void
      {
         if(actor == null || actor.thisStateBoard == null || actor.thisPro == null) return;
         if(this.invincible)
         {
            if(actor.thisAllHp > 0 && actor.thisCurHp < actor.thisAllHp)
            {
               actor.thisCurHp = actor.thisAllHp;
               actor.changState(0,"hp");
            }
            if(actor.thisAllMp > 0 && actor.thisCurMp < actor.thisAllMp)
            {
               actor.thisCurMp = actor.thisAllMp;
               actor.changState(0,"mp");
            }
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
         this.invincible = this.readFlag(parameters.invincible,true);
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
         this.showStartupMenu();
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

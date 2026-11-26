package §4399load_fla§
{
   import flash.display.*;
   import flash.events.*;

   [Embed(source="/_assets/assets.swf", symbol="symbol22")]
   public dynamic class mc_load_3 extends MovieClip
   {
      public var load_bar:MovieClip;

      public function mc_load_3()
      {
         super();
         addFrameScript(0,this.frame1);
      }

      internal function frame1() : void
      {
         stop();
      }

      public function load_inf(event:ProgressEvent) : void
      {
         if(this.load_bar == null || event.bytesTotal <= 0) return;
         var percent:int = Math.min(99,Math.floor(event.bytesLoaded / event.bytesTotal * 100));
         this.load_bar.bar_mc.scaleX = percent / 100;
         this.load_bar.t_txt.text = percent + "%";
      }

      public function loadFailed(message:String) : void
      {
         if(this.load_bar != null) this.load_bar.t_txt.text = "Load failed";
         trace("[AdventureKing] " + message);
      }
   }
}

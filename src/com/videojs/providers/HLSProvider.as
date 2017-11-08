package com.videojs.providers{

  import flash.media.Video;
  import flash.utils.ByteArray;
  import flash.net.NetStream;
  import flash.events.Event;

  import com.videojs.VideoJSModel;
  import com.videojs.events.VideoPlaybackEvent;
  import com.videojs.structs.ExternalErrorEventName;
  import com.videojs.structs.ExternalEventName;
  import com.videojs.structs.ReadyState;
  import com.videojs.structs.NetworkState;

  import org.mangui.hls.HLS;
  import org.mangui.hls.event.HLSEvent;
  import org.mangui.hls.event.HLSError;
  import org.mangui.hls.constant.HLSTypes;
  import org.mangui.hls.HLSSettings;
  import org.mangui.hls.constant.HLSPlayStates;
  import org.mangui.hls.constant.HLSSeekStates;
  import org.mangui.hls.utils.Log;
  import org.mangui.hls.utils.Params2Settings;
  import org.mangui.hls.model.Level;
  import org.mangui.hls.model.AudioTrack;
  import org.mangui.hls.playlist.AltAudioTrack;

  import by.blooddy.crypto.Base64;

  public class HLSProvider implements IProvider {

        private var _loop:Boolean = false;
        private var _looping:Boolean = false;
        private var _hls:HLS;
        private var _src:Object;
        private var _model:VideoJSModel;
        private var _videoReference:Video;
        private var _metadata:Object;
        private var _mediaWidth:Number;
        private var _mediaHeight:Number;

        private var _hlsState:String = HLSPlayStates.IDLE;
        private var _networkState:Number = NetworkState.NETWORK_EMPTY;
        private var _readyState:Number = ReadyState.HAVE_NOTHING;
        private var _position:Number = 0;
        private var _duration:Number = 0;
        private var _isAutoPlay:Boolean = false;
        private var _isManifestLoaded:Boolean = false;
        private var _isPlaying:Boolean = false;
        private var _isSeeking:Boolean = false;
        private var _isPaused:Boolean = true;
        private var _isEnded:Boolean = false;

        private var _bytesLoaded:Number = 0;
        private var _bytesTotal:Number = 0;
        private var _bufferedTime:Number = 0;
        private var _backBufferedTime:Number = 0;

        private var _currentBandwidth:Number = 0;
        private var _mediaRequests:Number = 0;
        private var _mediaRequestsErrored:Number = 0;
        private var _mediaRequestsTimedout:Number = 0;
        private var _mediaRequestsAborted:Number = 0;
        private var _mediaSecondsLoaded:Number = 0;
        private var _mediaBytesTransferred:Number = 0;
        private var _mediaTransferDuration:Number = 0;

        public function HLSProvider() {
          Log.info("https://github.com/brightcove/flashls");
          _hls = new HLS();
          _model = VideoJSModel.getInstance();
          _metadata = {};
          _hls.addEventListener(HLSEvent.PLAYBACK_COMPLETE,_completeHandler);
          _hls.addEventListener(HLSEvent.ID3_UPDATED,_id3UpdatedHandler);
          _hls.addEventListener(HLSEvent.ERROR,_errorHandler);
          _hls.addEventListener(HLSEvent.MANIFEST_LOADED,_manifestHandler);
          _hls.addEventListener(HLSEvent.MEDIA_TIME,_mediaTimeHandler);
          _hls.addEventListener(HLSEvent.PLAYBACK_STATE,_playbackStateHandler);
          _hls.addEventListener(HLSEvent.SEEK_STATE,_seekStateHandler);
          _hls.addEventListener(HLSEvent.LEVEL_SWITCH,_levelSwitchHandler);
          _hls.addEventListener(HLSEvent.CAPTION_DATA, _onCaptionDataHandler);
          _hls.addEventListener(HLSEvent.FRAGMENT_LOADED, _onFragmentLoaded);
          _hls.addEventListener(HLSEvent.FRAGMENT_LOAD_EMERGENCY_ABORTED, _onFragmentAborted);
        }

        private function _completeHandler(event:HLSEvent):void {
          if(!_loop){
            _isEnded = true;
            _isPaused = true;
            _isPlaying = false;
            _model.broadcastEvent(new VideoPlaybackEvent(VideoPlaybackEvent.ON_STREAM_CLOSE, {}));
            _model.broadcastEventExternally(ExternalEventName.ON_PAUSE);
            _model.broadcastEventExternally(ExternalEventName.ON_PLAYBACK_COMPLETE);
          } else {
            _looping = true;
            load();
          }
        };

        private function _id3UpdatedHandler(event:HLSEvent):void {
          _model.broadcastEventExternally(ExternalEventName.ON_ID3_UPDATED, event.ID3Data);
        };

        private function _errorHandler(event:HLSEvent):void {
          Log.debug("error!!!!:"+ event.error.msg);

          if (
            event.error.code === HLSError.FRAGMENT_LOADING_ERROR ||
            event.error.code === HLSError.FRAGMENT_PARSING_ERROR ||
            event.error.code === HLSError.FRAGMENT_LOADING_CROSSDOMAIN_ERROR
          ) {
            _mediaRequestsErrored++;
          }

          _model.broadcastErrorEventExternally(ExternalErrorEventName.SRC_404);
          _networkState = NetworkState.NETWORK_NO_SOURCE;
          _readyState = ReadyState.HAVE_NOTHING;
          stop();
        };

        private function _manifestHandler(event:HLSEvent):void {
          _isManifestLoaded = true;
          _networkState = NetworkState.NETWORK_IDLE;
          _readyState = ReadyState.HAVE_METADATA;
          _duration = event.levels[0].duration;
          _metadata.width = event.levels[0].width;
          _metadata.height = event.levels[0].height;
          if(_isAutoPlay || _looping) {
            _looping = false;
            play();
          }
          _model.broadcastEventExternally(ExternalEventName.ON_LOAD_START);
          _model.broadcastEventExternally(ExternalEventName.ON_DURATION_CHANGE, _duration);
          _model.broadcastEvent(new VideoPlaybackEvent(VideoPlaybackEvent.ON_META_DATA, {metadata:_metadata}));
          _model.broadcastEventExternally(ExternalEventName.ON_METADATA, _metadata);
        };

        private function _mediaTimeHandler(event:HLSEvent):void {
          _position = event.mediatime.position;
          _bufferedTime = event.mediatime.buffer+event.mediatime.position;
          _backBufferedTime = event.mediatime.position - event.mediatime.backbuffer;

          if(event.mediatime.duration != _duration) {
            _duration = event.mediatime.duration;
            _model.broadcastEventExternally(ExternalEventName.ON_DURATION_CHANGE, _duration);
          }
        };

        private function _playbackStateHandler(event:HLSEvent):void {
          _hlsState = event.state;
          Log.debug("state:"+ _hlsState);
          switch(event.state) {
              case HLSPlayStates.IDLE:
                _networkState = NetworkState.NETWORK_IDLE;
                _readyState = ReadyState.HAVE_METADATA;
                break;
              case HLSPlayStates.PLAYING_BUFFERING:
                _isPaused = false;
                _isEnded = false;
                _networkState = NetworkState.NETWORK_LOADING;
                _readyState = ReadyState.HAVE_CURRENT_DATA;
                _model.broadcastEventExternally(ExternalEventName.ON_BUFFER_EMPTY);
                if(!_isPlaying) {
                  _model.broadcastEventExternally(ExternalEventName.ON_RESUME);
                  _isPlaying = true;
                }
                break;
              case HLSPlayStates.PLAYING:
                _isPaused = false;
                _isEnded = false;
                _networkState = NetworkState.NETWORK_LOADING;
                _readyState = ReadyState.HAVE_ENOUGH_DATA;
                _model.broadcastEventExternally(ExternalEventName.ON_BUFFER_FULL);
                if(!_isPlaying) {
                  _model.broadcastEventExternally(ExternalEventName.ON_RESUME);
                  _isPlaying = true;
                }
                _model.broadcastEventExternally(ExternalEventName.ON_CAN_PLAY);
                _model.broadcastEvent(new VideoPlaybackEvent(VideoPlaybackEvent.ON_STREAM_START, {info:{}}));
                _model.broadcastEventExternally(ExternalEventName.ON_START);
                break;
              case HLSPlayStates.PAUSED:
                _isPaused = true;
                _isPlaying = false;
                _isEnded = false;
                _networkState = NetworkState.NETWORK_LOADING;
                _readyState = ReadyState.HAVE_ENOUGH_DATA;
                _model.broadcastEventExternally(ExternalEventName.ON_BUFFER_FULL);
                _model.broadcastEventExternally(ExternalEventName.ON_CAN_PLAY);
                break;
              case HLSPlayStates.PAUSED_BUFFERING:
                _isPaused = true;
                _isPlaying = false;
                _isEnded = false;
                _networkState = NetworkState.NETWORK_LOADING;
                _readyState = ReadyState.HAVE_CURRENT_DATA;
                _model.broadcastEventExternally(ExternalEventName.ON_BUFFER_EMPTY);
                break;
          }
        };


        private function _seekStateHandler(event:HLSEvent):void {
          switch(event.state) {
            case HLSSeekStates.SEEKED:
                _isSeeking = false;
                _model.broadcastEventExternally(ExternalEventName.ON_SEEK_COMPLETE);
                break;
            case HLSSeekStates.SEEKING:
                _isSeeking = true;
                _model.broadcastEventExternally(ExternalEventName.ON_SEEK_START);
                break;
          }
        }

        private function _levelSwitchHandler(event:HLSEvent):void {
            var levelIndex:Number = event.level;
            var bitrate:Number = _hls.levels[levelIndex].bitrate;
            var width:Number = _hls.levels[levelIndex].width;
            var height:Number = _hls.levels[levelIndex].height;
            Log.debug("HLSProvider: new level index " + levelIndex + " bitrate=" + bitrate + ", width=" + width + ", height=" + height);
            _model.broadcastEventExternally(ExternalEventName.ON_LEVEL_SWITCH, {levelIndex: levelIndex, bitrate: bitrate, width: width, height: height});
        }

        private function _onCaptionDataHandler(event:HLSEvent):void {
          var captionData:Array = event.captionData;
          var external:Array = [];

          for (var i: uint = 0; i < captionData.length; i++) {
            external.push({
              pos: captionData[i].pos,
              data: Base64.encode(captionData[i].data)
            });
          }

          _model.broadcastEventExternally(ExternalEventName.ON_CAPTION_DATA, external);
        }

        private function _onFrame(event:Event):void
        {
          var newWidth:Number = _videoReference.videoWidth;
          var newHeight:Number =  _videoReference.videoHeight;
          if  (newWidth != 0 &&
               newHeight != 0 &&
               newWidth != _mediaWidth &&
               newHeight != _mediaHeight)
          {
            _mediaWidth = newWidth;
            _mediaHeight = newHeight;
            Log.debug("video size changed to ("+newWidth+","+newHeight+")");
            _model.broadcastEvent(new VideoPlaybackEvent(VideoPlaybackEvent.ON_VIDEO_DIMENSION_UPDATE, {videoWidth: newWidth, videoHeight: newHeight}));
          }
        }

        /**
         * This is called whenever a segment is successfully loaded.
         *
         * Whenever a segment is loaded we keep metrics on a series of statistics, such as
         * - how many segments have been requested
         * - how many seconds of media have been downloaded
         * - how many bytes have been transferred
         * - how much times has been spent downloading segments
         * - what the bandwidth was for the latest downloaded segment
         */
        private function _onFragmentLoaded(event:HLSEvent):void
        {
          var metrics = event.loadMetrics;
          var fragmentTransferTime = metrics.parsing_end_time - metrics.loading_request_time;

          _mediaRequests++;

          if (!isNaN(metrics.duration)) {
            _mediaSecondsLoaded = _mediaSecondsLoaded + metrics.duration / 1000;
          }

          if (!isNaN(metrics.size)) {
            _mediaBytesTransferred = _mediaBytesTransferred + metrics.size;
          }

          if (!isNaN(fragmentTransferTime)) {
            _mediaTransferDuration = _mediaTransferDuration + fragmentTransferTime;
          }

          if (!isNaN(metrics.bandwidth)) {
            _currentBandwidth = metrics.bandwidth;
          }
        }

        private function _onFragmentAborted(event:HLSEvent):void
        {
          _mediaRequestsAborted++;
        }

        public function get loop():Boolean{
            return _loop;
        }

        public function set loop(pLoop:Boolean):void{
            _loop = pLoop;
        }

        /**
         * Should return a value that indicates the current playhead position, in seconds.
         */
        public function get time():Number {
          return _hls.liveSlidingMain ? _hls.liveSlidingMain + _position : _position;
        }

        /**
         * Should return a value that indicates the current asset's duration, in seconds.
         */
        public function get duration():Number  {
          if(_hls.type == HLSTypes.VOD) {
            return _duration;
          } else {
            return -1;
          }
        }

        /**
         * Should return a value that indicates the current seekable start, in seconds.
         */
        public function get seekableStart():Number {
          if(_hls.type == HLSTypes.LIVE) {
            return _hls.liveSlidingMain;
          } else {
            return 0;
          }
        }

        /**
         * Should return a value that indicates the current seekable end, in seconds.
         */
        public function get seekableEnd():Number {
          if(_hls.type == HLSTypes.VOD) {
            return _duration;
          } else {
            return _duration + _hls.liveSlidingMain;
          }
        }

       /**
         * Should return the list of audio-tracks that this content has.
         */
        public function get audioTracks():Array {
            var _audioTracks:Array = [];

            for each(var _audioTrack:AudioTrack in _hls['audioTracks']) {
              _audioTracks.push({
                id: _audioTrack.id,
                title: _audioTrack.title,
                source: _audioTrack.source,
                isDefault: _audioTrack.isDefault,
                isAAC: _audioTrack.isAAC
              });
            }

            return _audioTracks;
        }

        /**
         * Should return the list of alt-audio-tracks that this content has.
         */
        public function get altAudioTracks():Array {
            var _altAudioTracks:Array = [];

            for each(var _altAudioTrack:AltAudioTrack in _hls['altAudioTracks']) {
              _altAudioTracks.push(_altAudioTrack);
            }

            return _altAudioTracks;
        }

       /**
         * Should return index of the currently selected audio track
         */
        public function get audioTrack():int {
            return _hls['audioTrack'];
        }

        /**
          * Should select an audio track based on its is index in audio-track list
          */
        public function set audioTrack(pValue:int):void {
            _hls['audioTrack'] = pValue;

            if (!isNaN(_position) && pValue != -1) {
                 _hls.stream.seek(_position);
             }
        }

        /**
         * Appends the segment data in a ByteArray to the source buffer.
         * @param  bytes the ByteArray of data to append.
         */
        public function appendBuffer(bytes:ByteArray):void {
          throw "HLSProvider does not support appendBuffer";
        }

        /**
         * Should return an interger that reflects the closest parallel to
         * HTMLMediaElement's readyState property, as described here:
         * https://developer.mozilla.org/en/DOM/HTMLMediaElement
         */
        public function get readyState():int {
          return _readyState;
        }

        /**
         * Should return an interger that reflects the closest parallel to
         * HTMLMediaElement's networkState property, as described here:
         * https://developer.mozilla.org/en/DOM/HTMLMediaElement
         */
        public function get networkState():int {
          return _networkState;
        }

       /**
         * Should return an array of normalized time ranges currently
         * buffered of the media, in seconds.
         */
        public function get buffered():Array{
            if(_bufferedTime) {
                return _hls.liveSlidingMain ?
                    [[ _hls.liveSlidingMain + _backBufferedTime, _hls.liveSlidingMain + _bufferedTime ]] :
                    [[ _backBufferedTime, _bufferedTime ]];
            }
            return [];
        }

        /**
         * Should return the number of bytes that have been loaded thus far, or 0 if
         * this value is unknown or unable to be calculated (due to streaming, bitrate switching, etc)
         */
        public function get bufferedBytesEnd():int {
          return 0;
        }

        /**
         * Should return the number of bytes that have been loaded thus far, or 0 if
         * this value is unknown or unable to be calculated (due to streaming, bitrate switching, etc)
         */
        public function get bytesLoaded():int {
          return _mediaBytesTransferred;
        }

        /**
         * Should return the total bytes of the current asset, or 0 if this value is
         * unknown or unable to be determined (due to streaming, bitrate switching, etc)
         */
        public function get bytesTotal():int{
          return 0;
        }

        /**
         * Should return a boolean value that indicates whether or not the current media
         * asset is playing.
         */
        public function get playing():Boolean {
          Log.debug("HLSProvider.playing:"+_isPlaying);
          return _isPlaying;
        }

        /**
         * Should return a boolean value that indicates whether or not the current media
         * asset is paused.
         */
        public function get paused():Boolean {
          Log.debug("HLSProvider.paused:"+_isPaused);
          return _isPaused;
        }

        /**
         * Should return a boolean value that indicates whether or not the current media
         * asset has ended. This value should default to false, and be reset with every seek request within
         * the same asset.
         */
        public function get ended():Boolean {
          Log.debug("HLSProvider.ended:"+_isEnded);
          return _isEnded;
        }

        /**
         * Should return a boolean value that indicates whether or not the current media
         * asset is in the process of seeking to a new time point.
         */
        public function get seeking():Boolean {
          return _isSeeking;
        }

        /**
         * Should return a boolean value that indicates whether or not this provider uses the NetStream class.
         */
        public function get usesNetStream():Boolean {
          return true;
        }

        /**
         * Should return an object that contains metadata properties, or an empty object if metadata doesn't exist.
         */
        public function get metadata():Object {
          Log.debug("HLSProvider.metadata");
          return _metadata;
        }

        /**
         * Should return the most reasonable string representation of the current assets source location.
         */
        public function get srcAsString():String{
            if(_src != null){
                return _src.m3u8;
            }
            return "";
        }

        /**
         * Should contain an object that enables the provider to play whatever media it's designed to play.
         * Compare the difference in implementation between HTTPVideoProvider and RTMPVideoProvider to see
         * one example of how this object can be used.
         */
        public function set src(pSrc:Object):void {
          Log.debug("HLSProvider.src");
          _src = pSrc;
        }

        /**
         * Should return the most reasonable string representation of the current assets source location.
         */
        public function init(pSrc:Object, pAutoplay:Boolean):void {
          if (pSrc.parameters.hls_live_flushurlcache == undefined){
            // video-js integration uses a different setting from flashls's default.
            pSrc.parameters.hls_live_flushurlcache = true;
          }

          var cfg : Object = pSrc.parameters
          for (var object : String in cfg) {
            var subidx : int = object.indexOf("hls_");
              if (subidx != -1) {
                // Params2Settings sets Boolean HLSSettings attribute by simple type conversion.
                // If 'false' is set as a parameter, it's passed as string "false" here and that is converted to Boolean:true.
                // As workaround, this converts string 'false' to empty string, which will be converted to Boolean:false.
                if (cfg[object] == "false"){
                  cfg[object] = "";
                }
                Params2Settings.set(object.substr(4), cfg[object]);
              }
          }

          Log.debug("HLSProvider.init.");
          Log.debug("HLSSettings.logDebug=" + HLSSettings.logDebug);
          Log.debug("HLSSettings.logDebug2=" + HLSSettings.logDebug2);
          Log.debug("HLSSettings.minBufferLength=" + HLSSettings.minBufferLength);
          Log.debug("HLSSettings.lowBufferLength=" + HLSSettings.lowBufferLength);
          Log.debug("HLSSettings.maxBufferLength=" + HLSSettings.maxBufferLength);
          Log.debug("HLSSettings.startFromLevel=" + HLSSettings.startFromLevel);
          Log.debug("HLSSettings.seekFromLevel=" + HLSSettings.seekFromLevel);
          Log.debug("HLSSettings.flushLiveURLCache=" + HLSSettings.flushLiveURLCache);
          Log.debug("HLSSettings.seekMode=" + HLSSettings.seekMode);
          Log.debug("HLSSettings.manifestLoadMaxRetry=" + HLSSettings.manifestLoadMaxRetry);
          Log.debug("HLSSettings.fragmentLoadMaxRetry=" + HLSSettings.fragmentLoadMaxRetry);
          Log.debug("HLSSettings.capLevelToStage=" + HLSSettings.capLevelToStage);
          Log.debug("HLSSettings.maxLevelCappingMode=" + HLSSettings.maxLevelCappingMode);

          _src = pSrc;
          _isAutoPlay = pAutoplay;
          load();
          return;
        }

        /**
         * Called when the media asset should be preloaded, but not played.
         */
        public function load():void {
          if(_src !=null) {
            Log.debug("HLSProvider.load:"+ _src.m3u8);
            _isManifestLoaded = false;
            _position = 0;
            _duration = 0;
            _bufferedTime = 0;
            _hls.load(_src.m3u8);
          }
        }

        /**
         * Called when the media asset should be played immediately.
         */
        public function play():void {
          Log.debug("HLSProvider.play.state:" + _hlsState);
          if(_isManifestLoaded) {
            switch(_hlsState) {
              case HLSPlayStates.IDLE:
                _hls.stream.play();
                break;
              case HLSPlayStates.PAUSED:
              case HLSPlayStates.PAUSED_BUFFERING:
                _hls.stream.resume();
                break;
              default:
                break;
            }
          }
        }

        /**
         * Called when the media asset should be paused.
         */
        public function pause():void {
          Log.debug("HLSProvider.pause");
          _hls.stream.pause();
          _model.broadcastEventExternally(ExternalEventName.ON_PAUSE);
        }

        /**
         * Called when the media asset should be resumed from a paused state.
         */
        public function resume():void {
          Log.debug("HLSProvider.resume");
          _hls.stream.resume();
          _model.broadcastEventExternally(ExternalEventName.ON_RESUME);
        }

        /**
         * Called when the media asset needs to seek to a new time point.
         */
        public function seekBySeconds(pTime:Number):void {
          Log.debug("HLSProvider.seekBySeconds");
          if(_isManifestLoaded) {
            _position = pTime;
            _bufferedTime = _position;
            _hls.stream.seek(pTime);
          }
        }

        /**
         * Called when the media asset needs to seek to a percentage of its total duration.
         */
        public function seekByPercent(pPercent:Number):void {
          Log.debug("HLSProvider.seekByPercent");
          if(_isManifestLoaded) {
            _position = pPercent*_duration;
            _bufferedTime = _position;
            _hls.stream.seek(pPercent*_duration);
          }
        }

        /**
         * Called when the media asset needs to stop.
         */
        public function stop():void {
          Log.debug("HLSProvider.stop");
          _hls.stream.close();
          _bufferedTime = 0;
          _duration = 0;
          _position = 0;
          _networkState = NetworkState.NETWORK_EMPTY;
          _readyState = ReadyState.HAVE_NOTHING;
          _isManifestLoaded = false;
        }

        /**
         * For providers that employ an instance of NetStream, this method is used to connect that NetStream
         * with an external Video instance without exposing it.
         */
        public function attachVideo(pVideo:Video):void {
          _videoReference = pVideo;
          _videoReference.attachNetStream(_hls.stream);
          _hls.stage = pVideo.stage;
          _videoReference.addEventListener(Event.ENTER_FRAME, _onFrame);
          _model.broadcastEvent(new VideoPlaybackEvent(VideoPlaybackEvent.ON_STREAM_READY, {ns:_hls.stream as NetStream}));
          return;
        }

        /**
         * Called when the provider is about to be disposed of.
         */
        public function die():void {
          Log.debug("HLSProvider.die");
          stop();

          if(_videoReference) {
            _videoReference.clear();
          }
        }


        public function endOfStream():void{
            throw "HLSProvider does not support endOfStream";
        }

        public function abort():void{
            throw "HLSProvider does not support abort";
        }

        public function discontinuity():void{
            throw "HLSProvider does not support discontinuities";
        }

        /**
         * Should return the number of stream levels that this content has.
         */
        public function get numberOfLevels():int
        {
            return _hls.levels.length;
        }

        /**
         * Returns a list of stream levels that this content has.
         */
        public function get levels():Array
        {
          var _levels:Array = [];

          for each (var _level:Level in _hls['levels']) {
            _levels.push(_level);
          }

          return _levels;
        }

        /**
         * Should return the currently used stream level.
         */
        public function get level():int
        {
            return _hls['currentLevel'];
        }

        /**
         * Select the stream level.
         * If -1 is specified, it means auto selection.
         * If a level is specified (0-based index), that level is used and auto selection is disabled.
         */
        public function set level(pLevel:int):void
        {
            _hls['currentLevel'] = pLevel;

            // For reflecting new level from the next segment. Otherwise, new setting is applied only after currently buffered data is gone.
            if (!isNaN(_position) && pLevel != -1) {
                _hls.stream.seek(_position);
            }
        }

        /**
         * Gets the capping/max level value that could be used by automatic level
         * selection algorithm
         */
        public function get autoLevelCapping():int
        {
          return _hls['autoLevelCapping'];
        }

        /**
         * Sets the capping/max level value that could be used by automatic level
         * selection algorithm
         */
        public function set autoLevelCapping(pLevel:int):void
        {
          _hls['autoLevelCapping'] = pLevel;
        }

        /**
          * Should return whether auto level selection is currently enabled or not.
          */
        public function get autoLevelEnabled():Boolean
        {
            return _hls['autolevel'];
        }

        public function adjustCurrentTime(pValue:Number):void {
            // no-op
        }

        public function get videoPlaybackQuality():Object{
            if (_hls.stream != null &&
                _hls.stream.hasOwnProperty('totalFrames') &&
                _hls.stream.hasOwnProperty('droppedFrames')) {
                return {
                    droppedVideoFrames: _hls.stream.droppedFrames,
                    totalVideoFrames: _hls.stream.totalFrames
                };
            }
            return {};
        }

        public function get stats():Object {
          return {
            bandwidth: _currentBandwidth,
            mediaRequests: _mediaRequests,
            mediaRequestsAborted: _mediaRequestsAborted,
            mediaRequestsTimedout: 0,
            mediaRequestsErrored: _mediaRequestsErrored,
            mediaTransferDuration: _mediaTransferDuration,
            mediaBytesTransferred: _mediaBytesTransferred,
            mediaSecondsLoaded: _mediaSecondsLoaded
          }
        }
    }
}

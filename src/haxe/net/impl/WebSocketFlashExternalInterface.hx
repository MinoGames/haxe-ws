package haxe.net.impl;

import flash.external.ExternalInterface;
import haxe.extern.EitherType;
import haxe.io.Bytes;
import haxe.io.BytesData;
import haxe.net.WebSocket.ReadyState;

/**

Sample HTML:

Very important is giving an id to <object />

<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" lang="en" xml:lang="en">
	<head>
		<title>Cat Game</title>
		<meta http-equiv="Content-Type" content="text/html; charset=iso-8859-1" />
		<script type="text/javascript" src="swfobject.js"></script>
		<script type="text/javascript">
		swfobject.registerObject("myId", "9.0.0", "expressInstall.swf");
		</script>
	</head>
	<body style="background-color: #000000">
        <center>
            <div style="margin: auto auto">	
                <object id="myId" classid="clsid:D27CDB6E-AE6D-11cf-96B8-444553540000" width="563" height="1000">
                    <param name="movie" value="Main.swf" />
                    <param name="AllowScriptAccess" value="always">
                    <!--[if !IE]>-->
                    <object id="myId2" type="application/x-shockwave-flash" data="Main.swf" width="563" height="1000" AllowScriptAccess="always">
                    <!--<![endif]-->
                    <div>
                        <h1>Alternative content</h1>
                        <p><a href="http://www.adobe.com/go/getflashplayer"><img src="http://www.adobe.com/images/shared/download_buttons/get_flash_player.gif" alt="Get Adobe Flash player" /></a></p>
                    </div>
                    <!--[if !IE]>-->
                    </object>
                    <!--<![endif]-->
                </object>
            </div>
        </center>
	</body>
</html>

**/
class WebSocketFlashExternalInterface extends WebSocket {
    private var index:Int;
    static private var debug:Bool = false;

    static private var sockets = new Map<Int, WebSocketFlashExternalInterface>();

    public function new(url:String, protocols:Array<String> = null) {
        super();
        initializeOnce();

        this.index = ExternalInterface.call("function() {window.websocketjsList = window.websocketjsList || []; return window.websocketjsList.length; }");
        sockets[this.index] = this;

        var result:EitherType<Bool,String> = ExternalInterface.call("function(uri, protocols, index, objectID) {
            try {
                var flashObj = document.getElementById(objectID);
                var ws = (protocols != null) ? new WebSocket(uri, protocols) : new WebSocket(uri);
                ws.binaryType = 'arraybuffer';
                if (window.websocketjsList[index]) {
                    try {
                        window.websocketjsList[index].close();
                    } catch (e) {
                    }
                }
                window.websocketjsList[index] = ws;
                ws.onopen = function(e) { flashObj.websocketOpen(index); }
                ws.onclose = function(e) { flashObj.websocketClose(index); }
                ws.onerror = function(e) { flashObj.websocketError(index); }
                ws.onmessage = function(e) {
                    if (typeof e.data == 'string')
                        flashObj.websocketRecvString(index, e.data);
                    else
                        flashObj.websocketRecvBinary(index, Array.from(new Uint8Array(e.data)));
                }
                return true;
            } catch (e) {
                return 'error:' + e;
            }
        }", url, protocols, this.index, ExternalInterface.objectID);
        if(result != true) {
            throw result;
        }
    }

    static private var initializedOnce:Bool = false;
    static public function initializeOnce():Void {
        if (initializedOnce) return;
        if (debug) trace('Initializing websockets with javascript!');
        initializedOnce = true;
        ExternalInterface.addCallback('websocketOpen', function(index:Int) {
            if (debug) trace('js.websocketOpen[$index]');
            WebSocket.defer(function() {
                sockets[index].onopen();
            });
        });
        ExternalInterface.addCallback('websocketClose', function(index:Int) {
            if (debug) trace('js.websocketClose[$index]');
            WebSocket.defer(function() {
                sockets[index].onclose();
            });
        });
        ExternalInterface.addCallback('websocketError', function(index:Int) {
            if (debug) trace('js.websocketError[$index]');
            WebSocket.defer(function() {
                sockets[index].onerror('error');
            });
        });
        ExternalInterface.addCallback('websocketRecvString', function(index:Int, data:Dynamic) {
            if (debug) trace('js.websocketRecvString[$index]: $data');
            WebSocket.defer(function() {
                sockets[index].onmessageString(data);
            });
        });
        ExternalInterface.addCallback('websocketRecvBinary', function(index:Int, data:Dynamic) {
            if (debug) trace('js.websocketRecvBinary[$index]: $data');
            WebSocket.defer(function() {
                var bytes = new BytesData();
                for (index in 0...data.length)
                    bytes.writeByte(data[index]);
                sockets[index].onmessageBytes(Bytes.ofData(bytes));
            });
        });
    }

    override public function sendBytes(message:Bytes) {
        //_send(message.getData());
        
        var data = new Array<Int>();
        for (index in 0...message.length)
            data[index] = message.getInt32(index) & 0xFF;
        
        WebSocket.defer(function() {
            var result:EitherType<Bool,String> = ExternalInterface.call("function(index, data) {
                try {
                    window.websocketjsList[index].send(new Uint8Array(data).buffer);
                    return true;
                } catch (e) {
                    return 'error:' + e;
                }
            }", this.index, data);
            
            if(result != true) {
                throw result;
            }
        });
    }

    override public function sendString(message:String) {
        WebSocket.defer(function() {
            var result:EitherType<Bool,String> = ExternalInterface.call("function(index, message) {
                try {
                    window.websocketjsList[index].send(message);
                    return true;
                } catch (e) {
                    return 'error:' + e;
                }
            }", this.index, message);

            if(result != true) {
                throw result;
            }
        });
    }
    override function get_readyState():ReadyState {
        var state:Int = ExternalInterface.call("function(index) {
            return window.websocketjsList[index].readyState
        }", this.index);

		return switch(state) {
    		case 1: ReadyState.Open;
			case 3: ReadyState.Closed;
			case 2: ReadyState.Closing;
			case 0: ReadyState.Connecting;
			default: throw 'Unexpected websocket state';
		}
	}

    override public function process() {
    }

    static public function available():Bool {
        return ExternalInterface.available && ExternalInterface.call('function() { return (typeof WebSocket) != "undefined"; }');
    }
}
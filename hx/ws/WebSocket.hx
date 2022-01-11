package hx.ws;

import hx.ws.Types;

#if sys

#if (haxe_ver >= 4)
import sys.thread.Thread;
#elseif neko
import neko.vm.Thread;
#elseif cpp
import cpp.vm.Thread;
#end

#end

import haxe.crypto.Base64;
import haxe.io.Bytes;

enum ReadyState {
	Connecting;
	Open;
	Closing;
	Closed;
}

#if js
class WebSocket {
    dynamic static public function create(url:String, protocols:Array<String> = null, origin:String = null, debug:Bool = false):WebSocket {
        return new WebSocketJs(url, protocols);
    }

    static dynamic public function defer(callback: Void -> Void) {
        #if (flash || js)
        haxe.Timer.delay(callback, 0);
        #else
        callback();
        #end
    }

    public function process() {
    }

    public function sendString(message:String) {
    }

    public function sendBytes(message:Bytes) {
    }
	
	public function close() {
	}
	
	public var readyState(get, never):ReadyState;
	function get_readyState():ReadyState throw 'Not implemented';

    public dynamic function onopen():Void {
    }

    public dynamic function onerror(message:String):Void {
    }

    public dynamic function onmessageString(message:String):Void {
    }

    public dynamic function onmessageBytes(message:Bytes):Void {
    }

    public dynamic function onclose():Void {
    }
}
#elseif sys
class WebSocket extends WebSocketCommon {
    public var _protocol:String;
    public var _host:String;
    public var _port:Int = 0;
    public var _path:String;

    private var _processThread:Thread;
    private var _encodedKey:String = "wskey";

    public var binaryType:BinaryType;

    public var additionalHeaders(get, null):Map<String, String>;

    dynamic static public function create(url:String, protocols:Array<String> = null, origin:String = null, debug:Bool = false):WebSocket {
        #if flash
            if (haxe.net.impl.WebSocketFlashExternalInterface.available()) {
                return new haxe.net.impl.WebSocketFlashExternalInterface(url, protocols);
            }
        #end
        // return haxe.net.impl.WebSocketGeneric.create(url, protocols, origin, "wskey", debug);
        return new WebSocket(url);
    }

    private function new(url:String, immediateOpen=true) {
        parseUrl(url);
        onmessage = onmessageImpl;
        super(createSocket());

        if (immediateOpen) {
            open();
        }
    }

    inline private function parseUrl(url)
    {
        var urlRegExp = ~/^(\w+?):\/\/([\w\.-]+)(:(\d+))?(\/.*)?$/;

        if ( ! urlRegExp.match(url)) {
            throw 'Uri not matching websocket URL "${url}"';
        }

        _protocol = urlRegExp.matched(1);

        _host = urlRegExp.matched(2);

        var parsedPort = Std.parseInt(urlRegExp.matched(4));
        if (parsedPort > 0 ) {
            _port = parsedPort;
        }
        _path = urlRegExp.matched(5);
        if (_path == null || _path.length == 0) {
            _path = "/";
        }

    }

    private function createSocket():SocketImpl
    {
        if (_protocol == "wss") {
            #if (java || cs)
                throw "Secure sockets not implemented";
            #else
                if (_port == 0) {
                    _port = 443;
                }
                return new SecureSocketImpl();
            #end
        } else if (_protocol == "ws") {
            if (_port == 0) {
                _port = 80;
            }
            return new SocketImpl();
        } else {
            throw 'Unknown protocol $_protocol';
        }
    }


    public function open() {

        if (state != State.Handshake) {
            throw "Socket already connected";
        }
        _socket.setBlocking(true);
        _socket.connect(new sys.net.Host(_host), _port);
        _socket.setBlocking(false);

        #if !cs

        _processThread = Thread.create(processThread);
        _processThread.sendMessage(this);

        #else

        haxe.MainLoop.addThread(function() {
            Log.debug("Thread started", this.id);
            processLoop(this);
            Log.debug("Thread ended", this.id);
        });

        #end

        sendHandshake();
    }

    private function processThread() {
        Log.debug("Thread started", this.id);
        var ws:WebSocket = Thread.readMessage(true);
        processLoop(this);
        Log.debug("Thread ended", this.id);
    }

    private function processLoop(ws:WebSocket) {
        while (ws.state != State.Closed) { // TODO: should think about mutex
            ws.process();
            Sys.sleep(.01);
        }
    }

    function get_additionalHeaders() {
        if (additionalHeaders == null) {
            additionalHeaders = new Map<String, String>();
        }
        return additionalHeaders;
    }

    public function sendHandshake() {
        var httpRequest = new HttpRequest();
        httpRequest.method = "GET";
        // TODO: should propably be hostname+port+path?
        httpRequest.uri = _path;
        httpRequest.httpVersion = "HTTP/1.1";

        httpRequest.headers.set(HttpHeader.HOST, _host + ":" + _port);
        httpRequest.headers.set(HttpHeader.USER_AGENT, "hxWebSockets");
        httpRequest.headers.set(HttpHeader.SEC_WEBSOSCKET_VERSION, "13");
        httpRequest.headers.set(HttpHeader.UPGRADE, "websocket");
        httpRequest.headers.set(HttpHeader.CONNECTION, "Upgrade");
        httpRequest.headers.set(HttpHeader.PRAGMA, "no-cache");
        httpRequest.headers.set(HttpHeader.CACHE_CONTROL, "no-cache");
        httpRequest.headers.set(HttpHeader.ORIGIN, _socket.host().host.toString() + ":" + _socket.host().port);

        _encodedKey = generateWSKey();
        httpRequest.headers.set(HttpHeader.SEC_WEBSOCKET_KEY, _encodedKey);

        if (additionalHeaders != null) {
            for ( k in additionalHeaders.keys()) {
                httpRequest.headers.set(k, additionalHeaders[k]);
            }
        }

        sendHttpRequest(httpRequest);
    }

    private override function handleData() {
        switch (state) {
            case State.Handshake:
                var httpResponse = recvHttpResponse();
                if (httpResponse == null) {
                    return;
                }

                handshake(httpResponse);
                handleData();
            case _:
                super.handleData();
        }

    }

    private function handshake(httpResponse:HttpResponse) {
        if (httpResponse.code != 101) {
            if (onerror != null) {
                onerror(httpResponse.headers.get(HttpHeader.X_WEBSOCKET_REJECT_REASON));
            }
            close();
            return;
        }

        var secKey = httpResponse.headers.get(HttpHeader.SEC_WEBSOSCKET_ACCEPT);
        if (secKey != makeWSKeyResponse(_encodedKey)) {
            if (onerror != null) {
                onerror("Error during WebSocket handshake: Incorrect 'Sec-WebSocket-Accept' header value");
            }
            close();
            return;
        }

        _onopenCalled = false;
        state = State.Head;
    }

    private function generateWSKey():String {
        var b = Bytes.alloc(16);
        for (i in 0...16) {
            b.set(i, Std.random(255));
        }
        return Base64.encode(b);
    }

    public function onmessageImpl(m: MessageType):Void {
        switch (m) {
            case BytesMessage(data):
                this.onmessageBytes(data.readAllAvailableBytes());
            case StrMessage(str):
                this.onmessageString(str);
        }
    }

    public dynamic function onmessageString(message:String):Void {
    }

    public dynamic function onmessageBytes(message:Bytes):Void {
    }

    public function sendString(message:String) {
        if (readyState != Open) throw('websocket not open');
        send(message);
    }

    public function sendBytes(message:Bytes) {
        if (readyState != Open) throw('websocket not open');
        send(message);
    }

    // public var readyState(get, never):ReadyState;
	// function get_readyState():ReadyState throw 'Not implemented';

    public var readyState(get, never):ReadyState;
    public function get_readyState():ReadyState {
        return switch(state) {
            case Handshake: ReadyState.Connecting;
            case Head: ReadyState.Open;
            case HeadExtraLength: ReadyState.Open;
            case HeadExtraMask: ReadyState.Open;
            case Body: ReadyState.Open;
            case Closed: ReadyState.Closed;
        }
    }
}

#end

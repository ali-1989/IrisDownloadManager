import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';

// todo: can add interceptors and formatter by user,

class DownloadManager {
  String _name;
  int _concurrencyCount = 10;
  int _activeCount = 0;
  late BaseOptions _options;
  final List<DownloadItem> _allItems = [];
  final Queue<DownloadItem> _waitQueue = ListQueue(500);
  Map<String, CancelToken> _cancelLinker = {};
  String? _proxyUrl;
  bool _useProxy = false;
  bool isInitial = false;
  late StreamController<DownloadItem> _streamController;
  late Stream<DownloadItem> _streamListeners;

  bool _initial() {
    if(!isInitial || _streamController.isClosed) {
      _streamController = StreamController<DownloadItem>.broadcast();
      _streamListeners = _streamController.stream;
    }

    isInitial = true;
    return isInitial;
  }

  DownloadManager(String name, {int concurrencyCount = 10})
      : this._name = name,
        _concurrencyCount = concurrencyCount
  {
    _initial();
    _options = new BaseOptions(
      connectTimeout: Duration(seconds: 90),
      //receiveTimeout: 15000, no unComment
      //sendTimeout: 15000,
      followRedirects: true,
      maxRedirects: 4,
    );
  }

  DownloadManager.byOptions(String name, BaseOptions op)
      : this._name = name,
        this._options = op
  {
    _initial();
  }

  BaseOptions get options => _options;

  int get concurrencyCount => _concurrencyCount;

  String get name => _name;

  String? get proxyAddress => _proxyUrl;

  bool get useOfProxy => _useProxy;

  Stream<DownloadItem> getListenersStream() {
    return _streamListeners;
  }

  StreamSubscription addListener(void Function(DownloadItem di) fn) {//DownloadItem
    _initial();

    return _streamListeners.listen((event) {
      fn(event);
    }
    , onError: (err) {
      //fn();
    });
  }

  /*ListenerSubscription addListener(void fn(dynamic di)) {
		ListenerSubscription lis = ListenerSubscription(fn);
		listeners.add(lis);

		return lis;
	}

	void removeListener(void fn(dynamic di)) {
		ListenerSubscription cas = listeners.firstWhere((subscription) {
			if(subscription.handler == fn)
				return true;
			return false;
		});

		if(cas != null) {
			cas.cancel();
			listeners.remove(cas);
		}
	}*/

  void shutDown() {
    stopAll();
  }

  void purge() {
    stopAll();
    _streamController.close();
  }

  Future<void> start() async {
    _initial();
    _downloadNext();
  }

  void setProxyAddress(String url) {
    _proxyUrl = url;
  }

  void useProxy(bool state) {
    _useProxy = state;
  }

  Future<void> enqueue(DownloadItem item) async {
    if(item.isInProcess()) {
      return;
    }

    if(!_allItems.contains(item)){
      _allItems.add(item);
    }

    if (_activeCount >= _concurrencyCount) {
      if (!_waitQueue.contains(item)) {
        _waitQueue.addLast(item);
        item._state = DownloadState.queue;
      }

      return;
    }

    await _downloadItemIfCan(item);
  }

  Future<void> _downloadItemIfCan(DownloadItem item) async {
    if (_activeCount >= _concurrencyCount) {
      return;
    }

    _waitQueue.remove(item);
    item._countOfRetried = 0;

    await _process(item);
  }

  void _downloadNext() {
    if (_waitQueue.length < 1) {
      return;
    }

    final item = _waitQueue.removeFirst();
    _downloadItemIfCan(item);
  }

  Future<void> _process(DownloadItem item) async {
    _activeCount++;
    item._state = DownloadState.started;

    ProgressCallback progress = (int c, int total) {
      _onProgress(item, c, total);
    };

    var ct = CancelToken();
    var op = Options(
        responseType: item.responseType,
        headers: item.headers,
        method: item.httpMethod,
        receiveDataWhenStatusError: true,
    );

    if (item.savePath != null && !item.forceCreateNewFile) {
      File f = File(item.savePath!);
      int curSize = (await f.exists())? (await f.length()) : 0;

      if (curSize > 0) {
        item._savedSize = curSize;
        item.headers['range'] = "bytes=$curSize-";
        item.savePath = '${item.savePath}tempPart0';
      }
    }

    Dio dio = Dio(_options);

    _cancelLinker.remove(item._id);
    _cancelLinker[item._id] = ct;

    if (_useProxy && _proxyUrl != null) {
      (dio.httpClientAdapter as IOHttpClientAdapter).onHttpClientCreate = (client) {
        client.findProxy = (uri) {
          //return 'PROXY 95.174.67.50:18080';
          return 'PROXY $_proxyUrl';
        };

        client.badCertificateCallback = (X509Certificate cert, String host, int port) => true;

        return client;
      };
    }

    dio.interceptors.add(
        InterceptorsWrapper(
        onRequest: (RequestOptions options, RequestInterceptorHandler handler) {
          options.headers["Connection"] = "close";

          return handler.next(options);
        },
        onResponse: (Response<dynamic> res, ResponseInterceptorHandler handler) {
          item._response = res;
          String? r = res.headers.value('content-range');

          if (r != null) {
            item._rangeSize = num.parse(r.substring(r.indexOf('/') + 1)).toInt();
          }

          handler.next(res);
      })
    );

    Future f = dio.download(
        item.url,
        item.savePath,
        cancelToken: ct,
        queryParameters: item.queryParams,
        onReceiveProgress: progress,
        options: op,
        deleteOnError: false,
    );

    f = f.then((response) {
      if (response.statusCode > 199 && response.statusCode < 310) {
        _onComplete(item);
      }
      else {
        final data = response.data;

        // canceled by user
        if (data is DioError && CancelToken.isCancel(data)) {
          item._state = DownloadState.none;
          _cancelItem(item, null);
        }
        else {
          item._countOfRetried++;

          if (item.countOfRetry < item._countOfRetried) {
            _process(item);
          }
          else {
            _stopItem(item);
            _onError(item, 'bad statusCode');
          }
        }
      }
    });

    f.catchError((e) {
      if (e is DioError && CancelToken.isCancel(e)) {
        item._state = DownloadState.none;
        _cancelItem(item, null);
        return;
      }

      item._countOfRetried++;

      if (item._countOfRetried < item.countOfRetry)
        _process(item);
      else {
        _stopItem(item);
        _onError(item, e);
      }
    });
  }

  void _cancelItem(DownloadItem item, String? msg){
    _activeCount--;

    if(msg != null) {
      _cancelLinker[item.id]?.cancel(msg);
    }

    _cancelLinker.remove(item.id);
  }

  void _onProgress(DownloadItem item, int c, int total) {
    c += item._savedSize;
    item._receivedBytes = c;

    if (item.totalFileSize != null && item.totalFileSize! > 0) {
      item._progress = (c / item.totalFileSize! * 100).floorToDouble();
    }
    else if (item._rangeSize != null) {
      item._progress = (c / item._rangeSize! * 100).floorToDouble();
    }
    else if(total < 1) {
      item._progress = 0;
    }
    else {
      item._progress = (c / total * 100).floorToDouble();
    }

    _streamController.add(item);
  }

  void _onError(DownloadItem item, dynamic err) async {
    item._state = DownloadState.error;
    item.error = err;
    _cancelItem(item, err?.toString());
    await _assembleParts(item);

    _streamController.add(item);
    _downloadNext();
  }

  Future<void> _onComplete(DownloadItem item) async {
    item._state = DownloadState.completed;
    _cancelItem(item, null);

    await _assembleParts(item);

    _streamController.add(item);
    _downloadNext();
  }

  bool _stopItem(DownloadItem? item) {
    if(item == null) {
      return false;
    }

    item._state = DownloadState.stopped;
    _cancelItem(item, 'CancelByUser');

    // maybe not started yet
    _waitQueue.remove(item);

    _assembleParts(item);

    //prompt to listeners
    _streamController.add(item);
    return true;
  }

  void stopDownload(DownloadItem? item) {
    _stopItem(item);
    _downloadNext();
  }

  bool removeItemFromManager(DownloadItem item) {
    _stopItem(item);
    return _allItems.remove(item);
  }

  void stopDownloadById(String itemId) {
    stopDownload(getById(itemId));
  }

  void stopDownloadByUrl(String uri) {
    stopDownload(getByUrl(uri));
  }

  void stopDownloadByTag(String tag) {
    stopDownload(getByTag(tag));
  }

  List<DownloadItem> getCurrentDownloads(){
   final res = <DownloadItem>[];

   for(final i in _allItems){
     if(i._state == DownloadState.started){
       res.add(i);
     }
   }

   return res;
  }

  void stopAll() {
    getCurrentDownloads().forEach((item) {
      _stopItem(item);
    });
  }

  DownloadItem? getById(String id) {
    for (final i in _allItems) {
      if (i._id == id) {
        return i;
      }
    }

    return null;
  }

  DownloadItem? getByUrl(String url) {
    for (final i in _allItems) {
      if (i.url == url) {
        return i;
      }
    }

    return null;
  }

  DownloadItem? getByTag(String tag) {
    for (final i in _allItems) {
      if (i.tag == tag) {
        return i;
      }
    }

    return null;
  }

  DownloadItem? getByPath(String path) {
    for (final i in _allItems) {
      if (i.savePath == path) {
        return i;
      }
    }

    return null;
  }

  DownloadItem? getByAttachment(dynamic attach) {
    for (final i in _allItems) {
      if (i.attach == attach) {
        return i;
      }
    }

    return null;
  }

  double getProgressById(String id) {
    var item = getById(id);

    return item?.progress?? 0;
  }

  double getProgressByTag(String tag) {
    var item = getByTag(tag);

    return item?.progress?? 0;
  }

  Future _assembleParts(DownloadItem item) async {
    if (!item.forceCreateNewFile && item.savePath!.contains('tempPart')) {
      File f = File(item.savePath!);

      if (f.existsSync()) {
        String sp = item.savePath!.substring(0, item.savePath!.indexOf("tempPart"));

        await _mergeFiles(sp, item);
        item.savePath = sp;
      }
    }
  }

  Future _mergeFiles(String baseFile, DownloadItem item) async {
    File base = File(baseFile);
    File f2 = File(item.savePath!);

    try {
      IOSink ioSink = base.openWrite(mode: FileMode.writeOnlyAppend);
      await ioSink.addStream(f2.openRead());
      await f2.delete();
      await ioSink.close();
    }
    catch (e){
      _onError(item, e);
    }
  }

  DownloadItem createDownloadItem(String url, {required String tag, String? savePath}){
    var res = getByTag(tag);

    if(res == null && savePath != null) {
      res = getByPath(savePath);
    }

    if(res == null) {
      res = DownloadItem._(url: url, tag: tag, savePath: savePath);
    }

    return res;
  }
}
///======================================================================================================
enum DownloadState {
  none,
  queue,
  started,
  completed,
  stopped,
  error,
}
///======================================================================================================
class DownloadItem {
  late final String _id;
  late String url;
  late String tag;
  String? savePath;
  String? category;
  String? subCategory;
  String httpMethod = 'GET';
  int? totalFileSize;
  int? _rangeSize;
  int _savedSize = 0;
  dynamic attach;
  dynamic error;
  Response<dynamic>? _response;
  Map<String, String> queryParams = {};
  DownloadState _state = DownloadState.none;
  ResponseType responseType = ResponseType.bytes;
  Map<String, dynamic> headers = {};
  bool forceCreateNewFile = false;
  double _progress = 0;
  int _receivedBytes = 0;
  int countOfRetry = 5;
  int _countOfRetried = 0;

  DownloadItem._({
    required this.url,
    required this.tag,
    this.savePath,
  }): _id = _generateId(16);

  String get id => _id;
  DownloadState get state => _state;
  double get progress => _progress;
  int get receivedSize => _receivedBytes;
  Response<dynamic>? get response => _response;

  bool isComplete() {
    return _state == DownloadState.completed;
  }

  bool isDownloading() {
    return _state == DownloadState.started;
  }

  bool isStopped() {
    return _state == DownloadState.stopped;
  }

  bool isError() {
    return _state == DownloadState.error;
  }

  bool canReset() {
    return _state == DownloadState.error || _state == DownloadState.stopped || _state == DownloadState.none;
  }

  bool isInQueue() {
    return _state == DownloadState.queue;
  }

  bool isInProcess() {
    return _state == DownloadState.started || _state == DownloadState.queue;
  }

  bool isInCategory(String cat) {
    return category != null && category == cat;
  }

  bool isInSubCategory(String cat) {
    return subCategory != null && subCategory == cat;
  }

  static String _generateId(int max) {
    String s = 'abcdefghijklmnopqrstwxyz0123456789ABCEFGHIJKLMNOPQRSTUWXYZ';
    String res = '';
    Random r = Random();

    for (int i = 0; i < max; i++) {
      int j = r.nextInt(s.length);
      res += s[j];
    }

    return res;
  }
}

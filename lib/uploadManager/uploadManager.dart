import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:http_parser/http_parser.dart';

class UploadManager {
  String _name;
  int _concurrencyCount = 10;
  int _activeCount = 0;
  late BaseOptions _options;
  final List<UploadItem> _allItems = [];
  final Queue<UploadItem> _waitQueue = ListQueue(500);
  Map<String, CancelToken> _cancelLinker = {};
  String? _proxyUrl;
  bool _useProxy = false;
  bool isInitial = false;
  late StreamController<UploadItem> _streamController;
  late Stream<UploadItem> _streamListeners;
	

  bool _initial() {
    if(!isInitial || _streamController.isClosed) {
      _streamController = StreamController<UploadItem>.broadcast();
      _streamListeners = _streamController.stream;
    }

    isInitial = true;
    return isInitial;
  }

  UploadManager(String name, {int concurrencyCount = 10})
      : this._name = name,
        _concurrencyCount = concurrencyCount
  {
    _initial();
    _options = new BaseOptions(
      connectTimeout: Duration(seconds: 90),
    );
  }

  UploadManager.byOptions(String name, BaseOptions op)
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

  Stream<UploadItem> getListenersStream() {
    return _streamListeners;
  }

  StreamSubscription addListener(void Function(UploadItem di) fn) {
    _initial();

    return _streamListeners.listen((event) {
      fn(event);
    }
    , onError: (err) {
      //fn();
    });
	}

  void shutDown() {
    stopAll();
  }

  void purge() {
    stopAll();
    _streamController.close();
  }

  Future<void> start() async {
    _initial();
    _uploadNext();
  }

  void setProxyAddress(String url) {
    _proxyUrl = url;
  }

  void useProxy(bool state) {
    _useProxy = state;
  }

  Future<void> enqueue(UploadItem item) async {
    if(item.isInProcess()) {
      return;
    }

    if(!_allItems.contains(item)){
      _allItems.add(item);
    }

    if (_activeCount >= _concurrencyCount) {
      if (!_waitQueue.contains(item)) {
        _waitQueue.addLast(item);
        item._state = UploadState.queue;
      }

      return;
    }

    await _uploadItemIfCan(item);
  }

  Future<void> _uploadItemIfCan(UploadItem item) async {
    if (_activeCount >= _concurrencyCount) {
      return;
    }

    _waitQueue.remove(item);
    item._countOfRetried = 0;

    await _process(item);
  }

  void _uploadNext() {
    if (_waitQueue.length < 1) {
      return;
    }

    final item = _waitQueue.removeFirst();
    _uploadItemIfCan(item);
  }

  Future<void> _process(UploadItem item) async {
    _activeCount++;
    item._state = UploadState.started;

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

          handler.next(res);
      })
    );

		Future f = dio.request(
				item.url,
				cancelToken: ct,
				queryParameters: item.queryParams,
				onSendProgress: progress,
				options: op,
				data: item.data,
		);

		f = f.then((response) {
			//set in above: item._response = response;
			if (response != null && response.statusCode > 199 && response.statusCode < 310)
				_onComplete(item);
			else {
        final data = response.data;

        // canceled by user
        if (data is DioException && CancelToken.isCancel(data)) {
          item._state = UploadState.none;
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

    f = f.catchError((e) {
      if (e is DioException && CancelToken.isCancel(e)) {
        item._state = UploadState.none;
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

    item._state = UploadState.started;
	}

  void _cancelItem(UploadItem item, String? msg){
    _activeCount--;

    if(msg != null) {
      _cancelLinker[item.id]?.cancel(msg);
    }

    _cancelLinker.remove(item.id);
  }

  void _onProgress(UploadItem item, int c, int total) {
		item._progress = (c / total * 100).floorToDouble();
		item._sendBytes += c;

		_streamController.add(item);
	}

	void _onError(UploadItem item, dynamic err) {
		item._state = UploadState.error;
		item.error = err;
    _cancelItem(item, err?.toString());

		_streamController.add(item);
    _uploadNext();
	}

	void _onComplete(UploadItem item) {
		item._state = UploadState.completed;
    _cancelItem(item, null);

		_streamController.add(item);
		_uploadNext();
	}

	bool _stopItem(UploadItem? item) {
		if(item == null) {
			return false;
		}

		item._state = UploadState.stopped;
    _cancelItem(item, 'CancelByUser');

    _waitQueue.remove(item);

		_streamController.add(item); //prompt to listener
		return true;
	}

	void stopUpload(UploadItem? item) {
		_stopItem(item);
		_uploadNext();
	}

  bool removeItemFromManager(UploadItem item) {
    _stopItem(item);
    return _allItems.remove(item);
  }

  void stopUploadById(String itemId) {
    stopUpload(getById(itemId));
	}

	void stopUploadByTag(String tag) {
    stopUpload(getByTag(tag));
  }

  List<UploadItem> getCurrentUploads(){
   final res = <UploadItem>[];

   for(final i in _allItems){
     if(i._state == UploadState.started){
       res.add(i);
     }
   }

   return res;
  }

  void stopAll() {
    getCurrentUploads().forEach((item) {
      _stopItem(item);
    });
  }

	UploadItem? getById(String id) {
    for (final i in _allItems) {
      if (i._id == id) {
        return i;
      }
    }

    return null;
  }

    UploadItem? getByUrl(String url) {
    for (final i in _allItems) {
      if (i.url == url) {
        return i;
      }
    }

    return null;
  }

  UploadItem? getByTag(String tag) {
    for (final i in _allItems) {
      if (i.tag == tag) {
        return i;
      }
    }

    return null;
  }


  UploadItem? getByAttachment(dynamic attach) {
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

    UploadItem createUploadItem(String url, String tag){
    var res = getByTag(tag);

    if(res == null) {
    	res = UploadItem._(url: url, tag: tag);
    }

    return res;
  }
}
///======================================================================================================
enum UploadState {
  none,
  queue,
  started,
  completed,
  stopped,
  error,
}
///======================================================================================================
class UploadItem {
	late final String _id;
	late String url;
	late String tag; // this tag used for unique item
	String? category;
	String? subCategory;
	String httpMethod = 'POST';
	dynamic attach;
	dynamic data = FormData.fromMap({});
	Response<dynamic>? _response;
	Map<String, String> queryParams = {};
	UploadState _state = UploadState.none;
	dynamic error;
	ResponseType responseType = ResponseType.plain;
	Map<String, dynamic> headers = {};
	double _progress = 0;
	int _sendBytes = 0;
	int countOfRetry = 5;
	int _countOfRetried = 0;

	UploadItem._({
    required this.url,
    required this.tag,
  }): _id = UploadItem._generateId(16);

  String get id => _id;
  UploadState get state => _state;
  double get progress => _progress;
  Response<dynamic>? get response => _response;

  bool isComplete() {
    return _state == UploadState.completed;
  }

  bool isUploading() {
    return _state == UploadState.started;
  }

  bool isStopped() {
    return _state == UploadState.stopped;
  }

  bool isError() {
    return _state == UploadState.error;
  }

  bool canReset() {
    return _state == UploadState.error || _state == UploadState.stopped || _state == UploadState.none;
  }

  bool isInQueue() {
		return _state == UploadState.queue;
	}

	bool isInProcess() {
		return _state == UploadState.started || _state == UploadState.queue;
	}

  bool isInCategory(String cat) {
    return category != null && category == cat;
  }

  bool isInSubCategory(String cat) {
    return subCategory != null && subCategory == cat;
	}

	void addFile(String filePath, String partName, String fileName) {
		if(isInProcess()){
			throw Exception('in this state you can not add file');
		}

		MultipartFile m = MultipartFile.fromFileSync(filePath, filename: fileName, contentType: MediaType.parse('application/octet-stream'));
		MapEntry<String, MultipartFile> entry = MapEntry(partName, m);
		(data as FormData).files.add(entry);
	}

	void addBytes(List<int> bytes, String partName, String dataName) {
		if(isInProcess()){
			throw Exception('in this state you can not add data');
		}

		MultipartFile m = MultipartFile.fromBytes(bytes, filename: dataName, contentType: MediaType.parse('application/octet-stream'));
		(data as FormData).files.add(MapEntry(partName, m));
	}

	void addField(String data, String partName) {
		if(isInProcess()){
			throw Exception('in this state you can not add field');
		}

		MapEntry<String, String> entry = MapEntry(partName, data);
		(this.data as FormData).fields.add(entry);
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
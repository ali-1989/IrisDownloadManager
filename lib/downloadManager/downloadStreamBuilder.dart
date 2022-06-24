import 'dart:async';
import 'package:flutter/material.dart';
import 'downloadManager.dart';

class DownloadStreamBuilder extends StatefulWidget {
	final Stream<DownloadItem> stream;
	final AsyncWidgetBuilder<DownloadItem> builder;
	final DownloadItem downloadItem;

	const DownloadStreamBuilder({
		Key? key,
		required this.stream,
		required this.builder,
		required this.downloadItem,
	}) : super(key: key);

	AsyncSnapshot<DownloadItem> initial() {
		return AsyncSnapshot<DownloadItem>.withData(ConnectionState.none, downloadItem);
	}

	// start listen
	AsyncSnapshot<DownloadItem> afterConnected(AsyncSnapshot<DownloadItem> snapshot){
		return snapshot.inState(ConnectionState.waiting);
	}

	// onProgress, onComplete
	AsyncSnapshot<DownloadItem> afterData(AsyncSnapshot<DownloadItem> snapshot, DownloadItem data) {
		return AsyncSnapshot<DownloadItem>.withData(ConnectionState.active, data);
	}

	// onError
	AsyncSnapshot<DownloadItem> afterError(AsyncSnapshot<DownloadItem> snapshot, Object err) {
		return AsyncSnapshot<DownloadItem>.withError(ConnectionState.active, err);
	}

	// when stream be close
	AsyncSnapshot<DownloadItem> afterDone(AsyncSnapshot<DownloadItem> snapshot) => snapshot.inState(ConnectionState.done);

	// new widget instance
	AsyncSnapshot<DownloadItem> afterDisconnected(AsyncSnapshot<DownloadItem> snapshot) => snapshot.inState(ConnectionState.none);

	Widget build(BuildContext context, AsyncSnapshot<DownloadItem> snapshot) {
		return builder(context, snapshot);
	}

	@override
	State<DownloadStreamBuilder> createState(){
		return _DownloadStreamBuilderState();
	}
}
///======================================================================================================
class _DownloadStreamBuilderState extends State<DownloadStreamBuilder> {
	late StreamSubscription<dynamic> _subscription;
	late AsyncSnapshot<DownloadItem> _snapshot;

	@override
	void initState() {
		super.initState();

		_snapshot = widget.initial();
		_doListen();
	}

	@override
	void didUpdateWidget(DownloadStreamBuilder oldWidget) {
		super.didUpdateWidget(oldWidget);

		if (oldWidget.stream != widget.stream) {
			_unListen();
			_snapshot = widget.afterDisconnected(_snapshot);

			_doListen();
		}
	}

	@override
	Widget build(BuildContext context) => widget.build(context, _snapshot);

	@override
	void dispose() {
		_unListen();
		super.dispose();
	}

	void listenerData(DownloadItem downloadItem) {
		if(downloadItem.id != widget.downloadItem.id)
			return;

		setState(() {
			_snapshot = widget.afterData(_snapshot, downloadItem);
		});
	}

	void listenerError(Object ob) {
		//Map<String, dynamic> map = ob as Map<String, dynamic>;
		//DownloadItem d = map['item']; old
		DownloadItem d = ob as DownloadItem;

		if(d.id != widget.downloadItem.id)
			return;

		setState(() {
			_snapshot = widget.afterError(_snapshot, d.error); //map['error']
		});
	}

	void _doListen() {
		_subscription = widget.stream.listen(listenerData,
				/// when addError
				onError: listenerError,
				/// when stream be close
				onDone: () {
					setState(() {
						_snapshot = widget.afterDone(_snapshot);
					});
				}
		);

		//_snapshot = widget.afterConnected(_snapshot);
	}

	void _unListen() {
		_subscription.cancel();
	}
}
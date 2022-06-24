import 'dart:async';
import '../uploadManager/uploadManager.dart';
import 'package:flutter/material.dart';

class UploadStreamBuilder<ui extends UploadItem> extends StatefulWidget {
	final Stream<ui> stream;
	final AsyncWidgetBuilder<ui> builder;
	final ui uploadItem;

	const UploadStreamBuilder({
		Key? key,
		required this.stream,
		required this.builder,
		required this.uploadItem}) : super(key: key);

	AsyncSnapshot<ui> initial() => AsyncSnapshot<ui>.withData(ConnectionState.none, uploadItem);

	// start listen
	AsyncSnapshot<ui> afterConnected(AsyncSnapshot<ui> snapshot) => snapshot.inState(ConnectionState.waiting);

	// onProgress, onComplete
	AsyncSnapshot<ui> afterData(AsyncSnapshot<ui> snapshot, ui data) {
		return AsyncSnapshot<ui>.withData(ConnectionState.active, data);
	}

	// onError
	AsyncSnapshot<ui> afterError(AsyncSnapshot<ui> snapshot, Object err) {
		return AsyncSnapshot<ui>.withError(ConnectionState.active, err);
	}

	// when stream be close
	AsyncSnapshot<ui> afterDone(AsyncSnapshot<ui> snapshot) => snapshot.inState(ConnectionState.done);

	// new widget instance
	AsyncSnapshot<ui> afterDisconnected(AsyncSnapshot<ui> snapshot) => snapshot.inState(ConnectionState.none);

	Widget build(BuildContext context, AsyncSnapshot<ui> snapshot) => builder(context, snapshot);

	@override
	State<UploadStreamBuilder<ui>> createState() => _UploadStreamBuilderState<ui>();
}
///======================================================================================================
class _UploadStreamBuilderState<ui extends UploadItem> extends State<UploadStreamBuilder<ui>> {
	late StreamSubscription<dynamic> _subscription;
	late AsyncSnapshot<ui> _snapshot;

	@override
	void initState() {
		super.initState();

		_snapshot = widget.initial();
		_doListen();
	}

	@override
	void didUpdateWidget(UploadStreamBuilder<ui> oldWidget) {
		super.didUpdateWidget(oldWidget);

		if (oldWidget.stream != widget.stream) {
			_unListen();
			_snapshot = widget.afterDisconnected(_snapshot);
		}

		_doListen();
	}

	@override
	Widget build(BuildContext context) => widget.build(context, _snapshot);

	@override
	void dispose() {
		_unListen();
		super.dispose();
	}

	void listenerData(ui uploadItem) {
		if(uploadItem.id != widget.uploadItem.id)
			return;

		setState(() {
			_snapshot = widget.afterData(_snapshot, uploadItem);
		});
	}

	void listenerError(Object ob) {
		Map<String, dynamic> map = ob as Map<String, dynamic>;
		ui d = map['item'];

		if(d.id != widget.uploadItem.id)
			return;

		setState(() {
			_snapshot = widget.afterError(_snapshot, map['error']);
		});
	}

	void _doListen() {
		_subscription = widget.stream.listen(listenerData,
				// when addError
				onError: listenerError,
				// when stream be close
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

/* ===== createConnector patch (appended) ===== */
(function() {
    console.log('[ConnectorPatch] Initializing createConnector patch...');
    if (!window.DocsAPI || !window.DocsAPI.DocEditor) {
        console.warn('[ConnectorPatch] DocsAPI.DocEditor not found, skipping patch');
        return;
    }

    var _origDocEditor = window.DocsAPI.DocEditor;
    console.log('[ConnectorPatch] Wrapping DocsAPI.DocEditor');

    window.DocsAPI.DocEditor = function(placeholderId, config) {
        console.log('[ConnectorPatch] DocsAPI.DocEditor called with id:', placeholderId);
        // Save parent before the original replaces the placeholder div with an iframe
        var targetDiv = document.getElementById(placeholderId);
        var parentEl = targetDiv ? targetDiv.parentNode : null;
        console.log('[ConnectorPatch] targetDiv:', !!targetDiv, 'parentEl:', !!parentEl);

        // Call the original constructor
        var instance = _origDocEditor.apply(this, arguments);
        console.log('[ConnectorPatch] Original constructor returned:', typeof instance, instance ? Object.keys(instance).slice(0, 5) : 'null');

        // Find the editor iframe that replaced the placeholder
        var editorIframe = null;
        if (parentEl) {
            editorIframe = parentEl.querySelector('iframe[name="frameEditor"]');
        }
        if (!editorIframe) {
            // Fallback: find any frameEditor iframe
            editorIframe = document.querySelector('iframe[name="frameEditor"]');
        }
        console.log('[ConnectorPatch] editorIframe found:', !!editorIframe);

        // Add createConnector to the instance
        if (instance && editorIframe) {
            console.log('[ConnectorPatch] Adding createConnector to instance');
            instance.createConnector = function() {
                console.log('[ConnectorPatch] createConnector() called');
                var iframe = editorIframe;
                var guid = 'asc.{' + 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
                    var r = Math.random() * 16 | 0;
                    var v = c === 'x' ? r : (r & 0x3 | 0x8);
                    return v.toString(16);
                }) + '}';

                var methodCallbacks = [];
                var commandCallbacks = [];
                var eventHandlers = {};
                var contextMenuClickHandlers = {};
                var contextMenuIdCounter = 0;

                function sendToIframe(data) {
                    if (iframe && iframe.contentWindow) {
                        iframe.contentWindow.postMessage(JSON.stringify({
                            type: "onExternalPluginMessage",
                            subType: "connector",
                            data: data
                        }), "*");
                    }
                }

                function onMessageHandler(event) {
                    var parsed;
                    try {
                        parsed = typeof event.data === 'string' ? JSON.parse(event.data) : event.data;
                    } catch(e) {
                        return;
                    }
                    if (!parsed) return;

                    // Unwrap the callback envelope
                    if (parsed.type === "onExternalPluginMessageCallback") {
                        parsed = parsed.data;
                        if (!parsed) return;
                    }

                    if (parsed.guid !== guid) return;

                    switch (parsed.type) {
                        case "onMethodReturn": {
                            var cb = methodCallbacks.shift();
                            if (cb) cb(parsed.methodReturnData);
                            break;
                        }
                        case "onCommandCallback": {
                            var cb = commandCallbacks.shift();
                            if (cb) cb(parsed.commandReturnData);
                            break;
                        }
                        case "onEvent": {
                            var evtName = parsed.eventName;
                            if (evtName === "onContextMenuClick") {
                                // The plugin system appends "_oo_sep_" + extra data to the item ID.
                                // Strip it to match our stored handler keys.
                                var clickData = parsed.eventData || "";
                                var sepIdx = clickData.indexOf("_oo_sep_");
                                var itemId = sepIdx !== -1 ? clickData.substring(0, sepIdx) : clickData;
                                var clickHandler = contextMenuClickHandlers[itemId];
                                if (clickHandler) clickHandler();
                            }
                            var handler = eventHandlers[evtName];
                            if (handler) handler(parsed.eventData);
                            break;
                        }
                    }
                }

                window.addEventListener('message', onMessageHandler);

                // Register connector with the editor's plugin system
                sendToIframe({ type: "register", guid: guid });

                var connectorApi = {
                    executeMethod: function(name, params, callback) {
                        if (callback) methodCallbacks.push(callback);
                        sendToIframe({
                            type: "method",
                            guid: guid,
                            methodName: name,
                            data: params || []
                        });
                    },
                    callCommand: function(func, isClose, isCalc, callback) {
                        if (callback) commandCallbacks.push(callback);
                        sendToIframe({
                            type: "command",
                            guid: guid,
                            data: typeof func === 'function' ? '(' + func.toString() + ')()' : func,
                            recalculate: isCalc !== false,
                            resize: isClose !== false
                        });
                    },
                    attachEvent: function(name, callback) {
                        eventHandlers[name] = callback;
                        sendToIframe({ type: "attachEvent", guid: guid, name: name });
                    },
                    detachEvent: function(name) {
                        delete eventHandlers[name];
                        sendToIframe({ type: "detachEvent", guid: guid, name: name });
                    },
                    addContextMenuItem: function(items) {
                        if (!eventHandlers["onContextMenuClick"]) {
                            connectorApi.attachEvent("onContextMenuClick", function() {});
                        }
                        var protocolItems = [];
                        for (var i = 0; i < items.length; i++) {
                            var item = items[i];
                            var itemId = "connector_item_" + (++contextMenuIdCounter);
                            if (item.onClick) {
                                contextMenuClickHandlers[itemId] = item.onClick;
                            }
                            var protoItem = {
                                id: itemId,
                                text: item.text || "",
                                data: item.data || "",
                                disabled: !!item.disabled,
                                icons: item.icons || ""
                            };
                            // Only include items if there are actual sub-items.
                            // An empty array causes the web app to render a submenu
                            // arrow, preventing click events from firing.
                            if (item.items && item.items.length > 0) {
                                protoItem.items = item.items;
                            }
                            protocolItems.push(protoItem);
                        }
                        connectorApi.executeMethod("AddContextMenuItem", [{
                            guid: guid,
                            items: protocolItems
                        }]);
                    },
                    disconnect: function() {
                        window.removeEventListener('message', onMessageHandler);
                        sendToIframe({ type: "unregister", guid: guid });
                        methodCallbacks = [];
                        commandCallbacks = [];
                        eventHandlers = {};
                        contextMenuClickHandlers = {};
                    }
                };

                return connectorApi;
            };
        }

        return instance;
    };

    // Preserve static properties and methods
    window.DocsAPI.DocEditor.defaultConfig = _origDocEditor.defaultConfig;
    window.DocsAPI.DocEditor.version = _origDocEditor.version;
    if (_origDocEditor.warmUp) window.DocsAPI.DocEditor.warmUp = _origDocEditor.warmUp;
    for (var prop in _origDocEditor) {
        if (_origDocEditor.hasOwnProperty(prop) && !window.DocsAPI.DocEditor[prop]) {
            window.DocsAPI.DocEditor[prop] = _origDocEditor[prop];
        }
    }
})();

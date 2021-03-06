_                  = require 'lodash'
async              = require 'async'
Meshblu            = require 'meshblu-http'
MeshbluConfig      = require 'meshblu-config'
MeshbluRulesEngine = require 'meshblu-rules-engine'
RequestCache       = require '../helpers/cached-request'
DeviceCache        = require '../helpers/cached-device'
debug              = require('debug')('command-and-control:message-service')
debugError         = require('debug')('command-and-control:user-errors')
debugSlow          = require('debug')("command-and-control:slow-requests")
RefResolver        = require 'meshblu-json-schema-resolver'
Redlock            = require 'redlock'
SimpleBenchmark    = require 'simple-benchmark'

class MessageService
  constructor: ({ @route, @data, @device, @meshbluAuth, @timestampPath, @redis }) ->
    meshbluJSON = new MeshbluConfig().toJSON()
    @meshbluConfig = _.defaults(@meshbluAuth, meshbluJSON)
    commandAndControl = _.get @device, 'commandAndControl', {}
    @errorDevice = commandAndControl.errorDevice
    @rulesets ?= commandAndControl.rulesets ? @device.rulesets
    @skipRefResolver = commandAndControl.skipRefResolver
    @meshblu = new Meshblu @meshbluConfig
    @benchmarks = {}
    SimpleBenchmark.resetIds()
    @SLOW_MS = process.env.SLOW_MS || 3000
    @deviceCache = new DeviceCache { @meshblu, @redis }
    @requestCache = new RequestCache { @redis }
    @resolver = new RefResolver { @meshbluConfig }
    @redlock = new Redlock [@redis], retryCount: 60, retryDelay: 500

  resolve: (callback) =>
    async.retry {times: 5, interval: 10, errorFilter: @_retryErrorFilter}, @_resolve, callback

  _resolve: (callback) =>
    return callback() if @skipRefResolver

    @resolver.resolve @device, (error, resolvedDevice) =>
      debug "[#{error.uuid} as #{error.as || 'nobody'}]", error.message if error?
      return callback error if error?
      @device = resolvedDevice if resolvedDevice?
      callback()

  process: ({ benchmark }, callback) =>
    uuid = @device.uuid
    lockKey = "lock:uuid:#{uuid}"
    route = _.first @route
    unless _.isEmpty route
      lockKey = "lock:route:#{@device.uuid}:from:#{route.from}"
      uuid = route.from

    @redlock.lock lockKey, 30000, (error, lock) =>
      console.error error.stack if error?
      return _.defer @process, { benchmark }, callback unless lock?
      @benchmarks["redlock:#{lockKey}"] = "#{benchmark.elapsed()}ms"
      unlockCallback = (error) =>
        unlockBenchmark = new SimpleBenchmark { label: 'redlock:unlock' }
        lock.unlock =>
          @benchmarks['process:total'] = "#{benchmark.elapsed()}ms"
          @benchmarks['redlock:unlock'] = "#{unlockBenchmark.elapsed()}ms"
          @_logSlowRequest() if benchmark.elapsed() > @SLOW_MS
          return callback error

      timestampBenchmark = new SimpleBenchmark { label: 'future-timestamp' }
      @_isFutureTimestamp { uuid }, (error, canProcess) =>
        @benchmarks['future:timestamp'] = "#{timestampBenchmark.elapsed()}ms"
        return unlockCallback @_errorHandler(error) if error?
        unless canProcess
          error = new Error 'Refusing to process older message'
          error.code = 202
          return unlockCallback error

        return unlockCallback() if _.isEmpty @rulesets

        resolveBenchmark = new SimpleBenchmark { label: 'ref-resolve' }
        @resolve (error) =>
          @benchmarks["ref:resolve"] = "#{resolveBenchmark.elapsed()}ms"
          debug("failed to resolve #{uuid} for device #{@device.uuid}") if error?
          return unlockCallback @_errorHandler(error) if error?

          async.map @rulesets, async.apply(@_getRulesetWithLock, lock), (error, rulesMap) =>
            return unlockCallback @_errorHandler(error) if error?
            
            @_getFromDevice (error, fromDevice) =>
              return callback error if error?

              async.map _.compact(_.flatten(rulesMap)), async.apply(@_doRuleWithLock, lock, fromDevice), (error, results) =>
                return unlockCallback @_errorHandler(error) if error?
                commands = _.flatten results
                commands = @_mergeCommands commands
                async.each commands, async.apply(@_doCommandWithLock, lock), (error) =>
                  unlockCallback @_errorHandler(error)

  _isFutureTimestamp: ({ uuid }, callback) =>
    return callback null, true unless @timestampPath?
    currentTimestamp = _.get @data, @timestampPath
    return callback null, true unless currentTimestamp?
    @redis.get "cache:timestamp:#{uuid}", (error, previousTimestamp) =>
      return callback error if error?
      try
        previousTimestamp = JSON.parse previousTimestamp if previousTimestamp?
      catch error
        # ignore

      isFuture = true
      isFuture = currentTimestamp > previousTimestamp if previousTimestamp?
      return callback null, false unless isFuture
      @redis.set "cache:timestamp:#{uuid}", JSON.stringify(currentTimestamp), (error) =>
        console.error error.stack if error?
        return callback null, true

  _logSlowRequest: =>
    debugSlow(@meshbluAuth.uuid, 'benchmarks', @benchmarks)

  _mergeCommands: (commands) =>
    allUpdates = []
    mergedUpdates = {}
    _.each commands, (command) =>
      type = command.type
      uuid = command.params.uuid
      as = command.params.as
      operation = command.params.operation
      if type == 'meshblu' && operation != 'update'
        allUpdates.push command
        return

      key = _.compact([uuid, as, type, operation]).join('-')
      currentUpdate = mergedUpdates[key] ? command
      oldData = currentUpdate.params.data
      currentUpdate.params.data = _.merge oldData, command.params.data
      mergedUpdates[key] = currentUpdate

    return _.union allUpdates, _.values(mergedUpdates)

  _getRulesetWithLock: (lock, ruleset, callback) =>
    return callback() if _.isEmpty ruleset
    benchmark = new SimpleBenchmark { label: 'redlock:extend' }
    @benchmarks["redlock:extend"] ?= []
    lock.extend 30000, =>
      @benchmarks["redlock:extend"].push "#{benchmark.elapsed()}ms"
      @_getRuleset ruleset, callback

  _getRuleset: (ruleset, callback) =>
    return callback() unless ruleset.uuid?
    benchmark = new SimpleBenchmark { label: 'get-ruleset' }
    @deviceCache.get ruleset.uuid, (error, device) =>
      debug ruleset.uuid, error.message if error?.code == 404
      return callback @_addErrorContext(error, {ruleset}) if error?
      async.mapSeries device.rules, (rule, next) =>
        @requestCache.get rule.url, (error, data) =>
          return next @_addErrorContext(error, {rule}), data
      , (error, rules) =>
        @benchmarks["get-ruleset:#{ruleset.uuid}"] = "#{benchmark.elapsed()}ms"
        return callback error, _.flatten rules

  _doRuleWithLock: (lock, fromDevice, rulesConfig, callback) =>
    benchmark = new SimpleBenchmark { label: 'redlock:extend' }
    @benchmarks["redlock:extend"] ?= []
    lock.extend 30000, =>
      @benchmarks["redlock:extend"].push "#{benchmark.elapsed()}ms"
      @_doRule fromDevice, rulesConfig, callback

  _doRule: (fromDevice, rulesConfig, callback) =>
    benchmark = new SimpleBenchmark { label: 'do-rules' }
    context = { @data, @device, fromDevice }

    engine = new MeshbluRulesEngine {@meshbluConfig, rulesConfig, @skipRefResolver}
    engine.run context, (error, events) =>
      @_logInfo {rulesConfig, @data, @device, events}
      @benchmarks["do-rules"] ?= []
      @benchmarks["do-rules"].push "#{benchmark.elapsed()}ms"
      return callback @_addErrorContext(error, {rulesConfig, @data, @device, fromDevice}), events

  _getFromDevice: (callback) =>
    return callback null, @device if _.isEmpty @route
    @meshblu.device _.first(@route).from, (error, fromDevice) => callback null, fromDevice

  _doCommandWithLock: (lock, command, callback) =>
    benchmark = new SimpleBenchmark { label: 'redlock:extend' }
    @benchmarks["redlock:extend"] ?= []
    lock.extend 30000, =>
      @benchmarks["redlock:extend"].push "#{benchmark.elapsed()}ms"
      @_doCommand command, callback

  _doCommand: (command, callback) =>
    benchmark = new SimpleBenchmark { label: 'do-command' }
    done = (error) =>
      @benchmarks["do-command"] ?= []
      @benchmarks["do-command"].push "#{benchmark.elapsed()}ms"
      return callback @_addErrorContext(error, { command })
    return done new Error('unsupported command type') if command.type != 'meshblu'

    params  = _.get command, 'params', {}
    options = {}
    options.as = params.as if params.as?
    { operation } = params
    retry = params.retry || false

    return @meshbluUpdate {params, options, retry}, done if operation == 'update'
    return @meshbluMessage {params, options, retry}, done if operation == 'message'
    return done new Error('unsupported operation type')

  meshbluUpdate: ({params, options, retry}, callback) =>
    times = 1
    times = 5 if retry
    async.retry {times, interval: 10, errorFilter: @_retryErrorFilter}, async.apply(@_meshbluUpdate, params, options), callback

  _meshbluUpdate: (params, options, callback) =>
    { uuid, data } = params
    return callback new Error('undefined uuid') unless uuid?
    benchmark = new SimpleBenchmark { label: "meshblu:update:#{uuid}" }
    return @meshblu.updateDangerously uuid, data, options, (error) =>
      @benchmarks["meshblu:update:#{uuid}"] = "#{benchmark.elapsed()}ms"
      callback error

  meshbluMessage: ({params, options, retry}, callback) =>
    times = 1
    times = 5 if retry
    async.retry {times, interval: 10, errorFilter: @_retryErrorFilter}, async.apply(@_meshbluMessage, params, options), callback

  _meshbluMessage: (params, options, callback) =>
    { message } = params
    return callback new Error('undefined message') unless message?
    devices = _.join message?.devices, ','
    benchmark = new SimpleBenchmark { label: "meshblu:message:#{devices}" }
    return @meshblu.message message, options, (error) =>
      @benchmarks["meshblu:message:#{devices}"] = "#{benchmark.elapsed()}ms"
      callback error

  _addErrorContext: (error, context) =>
    return unless error?
    error.context ?= {}
    error.context = _.merge error.context, context
    return error

  _errorHandler: (error) =>
    return unless error?
    @_sendError error
    error.code = 422
    return error

  _logInfo: ({rulesConfig, data, device, events}) =>
    return unless @errorDevice?
    return unless @errorDevice.logLevel == 'info'

    message =
      devices: [ @errorDevice.uuid ]
      input: {data, deviceUuid: @device.uuid, device, rulesConfig}
      events: events

    @meshblu.message message, (error) =>
      return unless error?
      debug 'could not forward info message to meshblu'

  _retryErrorFilter: (error) => error.code >= 500

  _sendError: (error) =>
    errorMessage =
      devices: [ @errorDevice?.uuid ]
      error:
        stack: error.stack?.split('\n')
        context: error.context
        code: error.code
      input: {@data, deviceUuid: @device.uuid}

    debugError JSON.stringify({errorMessage},null,2)
    return unless @errorDevice?
    errorMessage.input = {@data, @device}

    @meshblu.message errorMessage, (error) =>
      return unless error?
      debug 'could not forward error message to meshblu'

module.exports = MessageService

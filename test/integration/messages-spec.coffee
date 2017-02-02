{afterEach, beforeEach, describe, it} = global
{expect} = require 'chai'
sinon = require 'sinon'

shmock        = require 'shmock'
request       = require 'request'
enableDestroy = require 'server-destroy'
Server        = require '../../src/server'
{clearCache}  = require '../../src/helpers/cached-request'
_ = require 'lodash'

describe 'POST /v1/messages', ->

  beforeEach (done) ->
    clearCache()
    @meshblu = shmock 0xd00d, [
      (req, res, next) =>
        { url, method, body } = req
        if url=='/messages' && method=='POST' && _.isEqual(body.devices, ['some-error-device'])
          @errorMessage = body
          return res.sendStatus(204)
        next()
    ]
    enableDestroy @meshblu

    @ruleServer = shmock 0xdddd
    enableDestroy @ruleServer

    @logFn = sinon.spy()
    serverOptions =
      port: undefined,
      disableLogging: true
      logFn: @logFn
      meshbluConfig:
        hostname: 'localhost'
        protocol: 'http'
        resolveSrv: false
        port: 0xd00d

    @server = new Server serverOptions

    @server.run =>
      @serverPort = @server.address().port
      done()

  afterEach ->
    @ruleServer.destroy()
    @meshblu.destroy()
    @server.destroy()

  beforeEach ->
    @errorMessage = undefined

    @userAuth = new Buffer('room-group-uuid:room-group-token').toString 'base64'

    @roomGroupDevice =
      uuid: 'room-group-uuid'
      rulesets: [
        uuid: 'ruleset-uuid'
      ]
      commandAndControl:
        errorDeviceId: 'some-error-device'

    @aRule =
      rules:
        add:
          conditions:
            all: [{
              fact: 'device'
              path: '.genisys.currentMeeting'
              operator: 'exists'
              value: true
            },{
              fact: 'device'
              path: '.genisys.inSkype'
              operator: 'notEqual'
              value: true
            }]
          event:
            type: 'meshblu'
            params:
              uuid: "{{data.genisys.devices.activities}}"
              operation: 'update'
              data:
                $set:
                  "genisys.activities.startSkype.people": []
      noevents: [ {
        type: 'meshblu'
        params:
          uuid: "{{data.genisys.devices.activities}}"
          operation: 'update'
          data:
            $set:
              "genisys.activities.startSkype.people": []
      }, {
        type: 'meshblu'
        params:
          operation: 'message'
          message:
            devices: ['erik-device']
            favoriteBand: 'santana'
      }]

    @bRule =
      rules:
        add:
          conditions:
            all: [{
              fact: 'device'
              path: '.genisys.currentMeeting'
              operator: 'exists'
              value: true
            },{
              fact: 'device'
              path: '.genisys.inSkype'
              operator: 'notEqual'
              value: true
            }]
          event:
            type: 'meshblu'
            params:
              uuid: "{{data.genisys.devices.activities}}"
              operation: 'update'
              data:
                $set:
                  "genisys.activities.startSkype.people": []
      noevents: [ {
        type: 'meshblu'
        params:
          uuid: "{{data.genisys.devices.activities}}"
          operation: 'update'
          data:
            $set:
              "genisys.activities.startSkypeAlso.people": []
      }]

    @rulesetDevice =
      uuid: 'ruleset-uuid'
      type: 'meshblu:ruleset'
      rules: [
        { url: "http://localhost:#{0xdddd}/rules/a-rule.json" }
        { url: "http://localhost:#{0xdddd}/rules/b-rule.json" }
      ]

    @options =
      uri: '/v1/messages'
      baseUrl: "http://localhost:#{@serverPort}"
      auth:
        username: 'room-group-uuid'
        password: 'room-group-token'
      json:
        uuid: 'room-uuid'
        genisys:
          devices:
            activities: 'activities-device-uuid'

    {@error, @response, @body} = {}

    @messageErikDeviceResponseCode ?= 204

    @setupShmocks = ()->
      @getARule = @ruleServer
        .get '/rules/a-rule.json'
        .reply 200, @aRule

      @getBRule = @ruleServer
        .get '/rules/b-rule.json'
        .reply 200, @bRule

      @authDevice = @meshblu
        .get '/v2/whoami'
        .set 'Authorization', "Basic #{@userAuth}"
        .reply 200, @roomGroupDevice

      @getRulesetDevice = @meshblu
        .get '/v2/devices/ruleset-uuid'
        .set 'Authorization', "Basic #{@userAuth}"
        .reply 200, @rulesetDevice

      @updateActivitiesDevice = @meshblu
        .put '/v2/devices/activities-device-uuid'
        .send {
          $set:
            "genisys.activities.startSkype.people": []
            "genisys.activities.startSkypeAlso.people": []
        }
        .reply 204

      @messageErikDevice = @meshblu
        .post '/messages'
        .send {
          devices: ['erik-device']
          favoriteBand: 'santana'
        }
        .reply @messageErikDeviceResponseCode

    @performRequest = (done) ->
      @setupShmocks()
      request.post @options, (@error, @response, @body) =>
        setTimeout =>
          done()
        , 100

  describe 'When everything works', ->
    beforeEach (done) ->
      @performRequest done

    it 'should return a 200', ->
      expect(@response.statusCode).to.equal 200

    it 'should not have an @errorMessage', ->
      expect(@errorMessage).to.not.be.defined

    it 'should auth the request with meshblu', ->
      @authDevice.done()

    it 'should fetch the ruleset device', ->
      @getRulesetDevice.done()

    it 'should get the rule url', ->
      @getARule.done()
      @getBRule.done()

    it 'should update the activities device', ->
      @updateActivitiesDevice.done()

    it 'should message Erik about his favorite band', ->
      @messageErikDevice.done()

  describe 'When everything works and we have no error message device', ->
    beforeEach (done) ->
      delete @roomGroupDevice.commandAndControl
      @performRequest done

    it 'should return a 200', ->
      expect(@response.statusCode).to.equal 200

  describe 'When we have an invalid ruleSet uuid', ->
    beforeEach (done) ->
      @roomGroupDevice.rulesets = [{uuid: 'unknown-uuid'}]
      @performRequest done

    it 'should return a 422', ->
      expect(@response.statusCode).to.equal 422

    it 'should contain the ruleset uuid in the error message', ->
      expect(@errorMessage.error.context).to.deep.equal ruleset: uuid: 'unknown-uuid'

  describe 'When we have an invalid ruleSet uuid and no error message device', ->
    beforeEach (done) ->
      @roomGroupDevice.rulesets = [{uuid: 'unknown-uuid'}]
      delete @roomGroupDevice.commandAndControl
      @performRequest done

    it 'should return a 422', ->
      expect(@response.statusCode).to.equal 422

    it 'should have no error message', ->
      expect(@errorMessage).to.not.exist

  describe 'When we have an invalid rule in the ruleSet', ->
    beforeEach (done) ->
      @badRule = { url: "http://localhost:#{0xdddd}/rules/c-rule.json" }
      @rulesetDevice.rules.push @badRule
      @performRequest done

    it 'should return a 422', ->
      expect(@response.statusCode).to.equal 422

    it 'should contain the rule url in the error message', ->
      expect(@errorMessage.error.context).to.deep.equal rule: @badRule

  describe 'When we update a device without a uuid', ->
    beforeEach (done) ->
      delete @options.json.genisys.devices.activities
      @performRequest done

    it 'should return a 422', ->
      expect(@response.statusCode).to.equal 422

    it 'should reference the failed command in the error message', ->
      expect(@errorMessage.error.context.command).to.exist

  describe 'When we message a device but get a 403', ->
    beforeEach (done) ->
      @messageErikDeviceResponseCode = 403
      @performRequest done

    it 'should return a 422', ->
      expect(@response.statusCode).to.equal 422

    it 'should reference the failed command in the error message', ->
      expect(@errorMessage.error.context.command).to.exist

    it 'should have a 403 code in the error', ->
      expect(@errorMessage.error.code).to.equal 403

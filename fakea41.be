#- 

FakeA41

Tasmota enabled DIY Replacement for brp069a41 wifi modules on Daikin A/C units.

Info at: https://github.com/msx80/FakeA41

-#

import string
import mqtt

# Pins for software serial, adjust as needed

GPIO_RX = 6
GPIO_TX = 4

# Home Assistant setup

HA_UNIQUE_NAME = "FA41-"+tasmota.cmd("DeviceName")["DeviceName"]
HA_DISPLAY_NAME = "FA41-"+tasmota.cmd("FriendlyName")["FriendlyName1"]
HA_TOPIC_PREFIX = "fa41/"+HA_UNIQUE_NAME+"/"

HA_MODE_COMMAND_TOPIC = HA_TOPIC_PREFIX+"mode/set"
HA_MODE_STATE_TOPIC = HA_TOPIC_PREFIX+"mode/state"

HA_TEMP_COMMAND_TOPIC = HA_TOPIC_PREFIX+"temp/set"
HA_TEMP_STATE_TOPIC = HA_TOPIC_PREFIX+"temp/state"

HA_FAN_COMMAND_TOPIC = HA_TOPIC_PREFIX+"fan/set"
HA_FAN_STATE_TOPIC = HA_TOPIC_PREFIX+"fan/state"

HA_CURRENT_TEMP_TOPIC =  HA_TOPIC_PREFIX+"currentTemp/state";
HA_OUTSIDE_TEMP_TOPIC =  HA_TOPIC_PREFIX+"outsideTemp/state";

# TODO create a single device discovery instead of multiple components

PRESENCE = 
'{'
'  "name": "'+HA_DISPLAY_NAME+'",'
'  "uniq_id": "'+HA_UNIQUE_NAME+'",'
'  "modes": ["auto", "off", "cool", "heat", "dry", "fan_only"],'
'  "fan_modes": ["AUTO", "NIGHT", "1", "2", "3", "4", "5"],'
'  "min_temp": 16,'
'  "max_temp": 30,'
'  "temp_step": 1,'
'  "fan_mode_command_topic": "'+HA_FAN_COMMAND_TOPIC+'",'
'  "fan_mode_state_topic": "'+HA_FAN_STATE_TOPIC+'",'
'  "mode_command_topic": "'+HA_MODE_COMMAND_TOPIC+'",'
'  "mode_state_topic": "'+HA_MODE_STATE_TOPIC+'",'
'  "temperature_command_topic": "'+HA_TEMP_COMMAND_TOPIC+'",'
'  "temperature_state_topic": "'+HA_TEMP_STATE_TOPIC+'",'
'  "dev": {'
'    "ids": ["Dev'+HA_UNIQUE_NAME+'"],'
'    "name": "Daikin '+HA_DISPLAY_NAME+'"'
'  }'
'}'

 #'  "current_temperature_topic": "'+HA_CURRENT_TEMP_TOPIC+'",'
 
PRESENCE_INSIDE_TEMP = 
'{'
'  "name": "'+HA_DISPLAY_NAME+' Inside Temperature",'
'  "unique_id": "'+HA_UNIQUE_NAME+'-Inside",'
'  "state_topic": "'+HA_CURRENT_TEMP_TOPIC+'",'
'  "device_class": "temperature",'
'  "unit_of_measurement":"°C",'
'  "dev": {'
'    "ids": ["Dev'+HA_UNIQUE_NAME+'"],'
'    "name": "Daikin '+HA_DISPLAY_NAME+'"'
'  }'
'}'

PRESENCE_OUTSIDE_TEMP = 
'{'
'  "name": "'+HA_DISPLAY_NAME+' Outside Temperature",'
'  "unique_id": "'+HA_UNIQUE_NAME+'-Outside",'
'  "state_topic": "'+HA_OUTSIDE_TEMP_TOPIC+'",'
'  "device_class": "temperature",'
'  "unit_of_measurement":"°C",'
'  "dev": {'
'    "ids": ["Dev'+HA_UNIQUE_NAME+'"],'
'    "name": "Daikin '+HA_DISPLAY_NAME+'"'
'  }'
'}'

# decoding table for JSON messages

MODE_CODES = {
	'cool': 0x33,
	'heat': 0x34,
	'fan_only': 0x36,
	'dry': 0x32,
	'auto': 0x31
}

FAN_CODES = {
	'AUTO': 0x41,
	'NIGHT': 0x42,
	'1': 0x33,
	'2': 0x34,
	'3': 0x35,
	'4': 0x36,
	'5': 0x37
}

class State
	var active
	var mode
	var targetTemp
	var fan
	var insideTemp
	var outsideTemp
	var swingH
	var swingV
	
	def clone()
	    var n = State()
	    n.active = self.active
	    n.mode = self.mode
	    n.targetTemp = self.targetTemp
	    n.fan = self.fan
	    n.insideTemp = self.insideTemp
	    n.outsideTemp = self.outsideTemp
	    n.swingH = self.swingH
	    n.swingV = self.swingV
	    return n
	end
end


#========= Utils

def invertMap(amap)
  var res = {}
  for i : amap.keys()
	res[amap[i]]=i
  end
  return res;
end


MODE_CODES_INV = invertMap(MODE_CODES)
FAN_CODES_INV = invertMap(FAN_CODES)


#========= Checksum Functions

def calcChecksum(buf)
	var sum = 0
	for i : 1..buf.size()-3
		sum = sum + buf[i]
	end
	return sum%256
end

def setChecksum(buf)
	var cs = calcChecksum(buf)
	buf[buf.size()-2] = cs
end

def verifyChecksum(buf)
	var cs = calcChecksum(buf)
	if buf[buf.size()-2] != cs
		raise "io_error", "Invalid checksum"
	end
end


#========= Serial IO utilities

def readWithTimeout(ser, timeoutMillis)
	var start = tasmota.millis()
	while ser.available() == 0
		var now = tasmota.millis()
		if now-start >= timeoutMillis
			return bytes()
		end
	end
	return ser.read()
end


#-

 Read single bytes from serial port with buffer and timeout.
 The standard serial.read() always return the whole buffer, so
 you can't read byte by byte easily. With this class you can.

-#

class SerReader

	var ser 	# serial connection
	var buffer	# buffer with available data
	var timeout	# timeout in millis for reads

	def init(ser, timeout)
		self.ser = ser
		self.timeout = timeout
		self.buffer = bytes()
	end

	def readByte()
       	if self.buffer.size() >= 1
			var res = self.buffer[0]
			self.buffer = self.buffer[1..-1] # perhaps we could keep a cursor to avoid copying the buffer every time
			return res 
		else
			self.buffer = readWithTimeout(self.ser, self.timeout)
			if self.buffer.size() == 0
		    		return nil
			else
				return self.readByte() # tail recurse now that buffer is full
			end
		end
	end

	def readByteOrRaise()
		var b = self.readByte()
		if b == nil
			raise "io_error", "Timeout reading from serial"
		end
		return b
	end

	def available()
		# the total amount of bytes available are those in the local buffer
		# plus those in the serial buffer
		return self.buffer.size() + self.ser.available()
	end
	
	def cleanBuffers()
		self.buffer = bytes()
		self.ser.read()
	end

	def write(data)
		self.ser.write(data)
	end
end



#========= S21 Protocol stuff


# read a single byte and check it's 06 (ACK)
def readAck(reader)
	var head = reader.readByteOrRaise()
	if head != 6
		raise "io_error", "Invalid ack"
	end
end

# read a packet from 02 (STX) to 03 (ETX)
def readRawPacket(reader)
	var buffer = bytes()
	var head = reader.readByteOrRaise()
	if head != 2
		raise "io_error", "Bad start of pkt"
	end
	buffer..head
	while true
		var b = reader.readByteOrRaise()
		buffer..b
		if b == 3 
			return buffer
		else
			if buffer.size()>100
				raise "io_error", "Message too long"
			end
		end
	end
end


# read a complete reply: ack + packet and check the checksum
# return the packet 
def readReply(reader)
	readAck(reader)
	var pkt = readRawPacket(reader)
	verifyChecksum(pkt)
	log("Daiking Receiving "+pkt.tohex(), 3)
	return pkt
end

def writePacket(reader, pkt)
	# before sending a packet we discard the input buffer
	# to get rid of any unexpected input from the device.
	# this way in the event of a desincronization 
	# we can reestablish communication
	reader.cleanBuffers()

	setChecksum(pkt)
	log("Daiking Sending "+pkt.tohex(), 3)
	reader.write(pkt)
end

# Extract the temperature from a temperature-reporting package
def extractTemperature(pkt)
	# es 025361 3035302B 7403
	# es 025348 3030322B 5803
	var astr = pkt[3..6].asstring()
	var res = astr[2]+astr[1]+"."+astr[0]
	# only add sign if it's minus, json number can't start with +
	if astr[3] != '+'
		res = astr[3]+res
	end
	return res
end

def readVersion(reader)
	writePacket(reader, bytes("024638FF03"))
	var pkt = readReply(reader)
	# sample resp 02 47 38 30 32 30 30 4103
	#                      0  2 0 0
	return pkt[3..6].asstring()
end

def readHumidity(reader)
	writePacket(reader, bytes("025265FF03"))
	var pkt = readReply(reader)
	log("Humidity "+pkt.tohex())
	return 0
end


def readSwingState(reader)
	writePacket(reader, bytes("024635FF03"))
	var pkt = readReply(reader)

	# sample:
	# Daiking Sending 0246357B03
	# Daiking Receiving 024735313F30809C03
	
	# 02 4735 30303080 8C03 - None
	# 02 4735 313F3080 9C03 - Vertical
	# 02 4735 323F3080 9D03 - Horizontal
	# 02 4735 373F3080 A203 - Both
	
	# returns [horz, vert]
	
	var b = pkt[3]
	if b == 0x30
		return [false, false]
	elif b == 0x31
		return [false, true]
	elif b == 0x32
		return [true, false]
	else 
		return [true, true]
	end
end

def readFanState(reader)
    # note: Command D1 will acknowledge and apply the quiet ("B") fan setting, 
    # but command F1 will read it back as if the fan was set to "Auto" mode. 
    # Command RG, however, which uses the same mode values as D1 and F1, will 
    # correctly return "B" if the fan is in quiet mode.
	writePacket(reader, bytes("025247FF03"))
	var pkt = readReply(reader)

    var fan = FAN_CODES_INV[pkt[3]]
	return fan
end

def readOutsideTemperature(reader)
	writePacket(reader, bytes("025261b303"))
	var pkt = readReply(reader)
	return extractTemperature(pkt)
end

def readInsideTemperature(reader)
	writePacket(reader, bytes("0252489a03"))
	var pkt = readReply(reader)
	return extractTemperature(pkt)
end

def readUnitStateObj(reader)
	writePacket(reader, bytes("0246317703"))
	var pkt = readReply(reader)
	
	var active = pkt[3] == 0x31 ? true : false
	var mode = MODE_CODES_INV[pkt[4]]
	var temperature = (pkt[5]-28)/2.0
	
	# this has a bug with NIGHT fan mode
	# var fan = FAN_CODES_INV[pkt[6]]	
	var fan = readFanState(reader)
	
	var res = State()
	res.active = active
	res.mode = mode
	res.targetTemp = temperature
	res.fan = fan
	
	return res;
end

def writeSwings(reader, swingV, swingH)
	var cmd = bytes("024435FFFF30800003")
	if swingV && swingH
		cmd[3] = 0x37
	elif swingV
		cmd[3] = 0x31
	elif swingH
		cmd[3] = 0x32
	else
		cmd[3] = 0x30
	end

	cmd[4] = (cmd[3] == 0x30) ? 0x30 : 0x3F
	writePacket(reader, cmd)
	readAck(reader)
end

def writeCommand(reader, active, mode, temperature, fan)
	var cmd = bytes("024431FFFFFFFF0003")

	cmd[3] = active ? 0x31 : 0x30
	cmd[4] = MODE_CODES[mode]
	cmd[5] = int(temperature * 2) + 28
	cmd[6] = FAN_CODES[fan]

	writePacket(reader, cmd)
	readAck(reader)
end


#====== Main interface classes

class FakeA41

	var reader
	var lastState
	
	def init()
		var ser = serial(GPIO_RX, GPIO_TX, 2400, serial.SERIAL_8E2)
		self.reader = SerReader(ser, 1000)
		var version = readVersion(self.reader)
		log("Daikin protocol version: "+str(version))
		self.getState()
		log("FakeA41 initialization complete")
	end
	
	def getState()
		log("Reading full state")
		var outT = readOutsideTemperature(self.reader)
		var inT = readInsideTemperature(self.reader)
		var swings = readSwingState(self.reader)
		self.lastState = readUnitStateObj(self.reader)
		self.lastState.insideTemp = inT
		self.lastState.outsideTemp = outT
		self.lastState.swingH = swings[0]
		self.lastState.swingV = swings[1]
		return self.lastState
	end

	# send a command to the unit.
	# active boolean
	# mode, fan string
	# targetTemp number
	# swing* boolean
	def fullCommand(active, mode, fan, targetTemp, swingH, swingV)
		
		# first set the swings so if anything goes bad the state is unchanged
		# only send if turning on, no need to set if powering down
		if active 
			writeSwings(self.reader, swingV, swingH)
		end

		# write the actual command
		writeCommand(self.reader, active, mode, targetTemp, fan)

			
	end
	
	# send a command to the unit.
	# active boolean
	# mode, fan string
	# targetTemp number
	def command(active, mode, fan, targetTemp)
		
		writeCommand(self.reader, active, mode, targetTemp, fan)

			
	end

end




#========= Main driver class

class FakeA41Driver : Driver

	var fa41
	
	def every_second()
		var oldState = self.fa41.lastState
		self.fa41.getState()
		var newState = self.fa41.lastState
		if ( oldState.targetTemp != newState.targetTemp ) ||
		   ( oldState.mode != newState.mode) ||
		   ( oldState.fan != newState.fan) ||
		   ( oldState.active != newState.active) ||
		   ( oldState.insideTemp != newState.insideTemp) ||
		   ( oldState.outsideTemp != newState.outsideTemp)
		   log("Change in state detected!")
		   self.sendState(newState)
		end
	end
	
	def mqttConnected()
		log("MQTT is connected!")
		if mqtt.connected()
				log("sending PRESENCE")
				mqtt.publish("homeassistant/climate/"+HA_UNIQUE_NAME+"/config", PRESENCE, true)
				mqtt.publish("homeassistant/sensor/"+HA_UNIQUE_NAME+"-Inside/config", PRESENCE_INSIDE_TEMP, true)
				mqtt.publish("homeassistant/sensor/"+HA_UNIQUE_NAME+"-Outside/config", PRESENCE_OUTSIDE_TEMP, true)
				log("PRESENCE sent, sending state!")
				self.sendState(self.fa41.lastState)
				log("state sent")
		end
	end
    	
    	def sendState(state)
    		if mqtt.connected()
    		    if state.active
    		        mqtt.publish(HA_MODE_STATE_TOPIC, state.mode)
    		    else
    		        mqtt.publish(HA_MODE_STATE_TOPIC, "off")
    		    end
    			mqtt.publish(HA_TEMP_STATE_TOPIC, str(state.targetTemp))
    			mqtt.publish(HA_FAN_STATE_TOPIC, state.fan)
    			mqtt.publish(HA_CURRENT_TEMP_TOPIC, str(state.insideTemp))
    			mqtt.publish(HA_OUTSIDE_TEMP_TOPIC, str(state.outsideTemp))
    		end
    	end
    	
    	def tempSet(tempStr)
    		var temp = number(tempStr)
    		var s = self.fa41.lastState.clone()
    		self.fa41.command(s.active, s.mode, s.fan, temp)
    		return true;
    	end
    	
    	def fanSet(fanStr)
    		var s = self.fa41.lastState.clone()
    		self.fa41.command(s.active, s.mode, fanStr, s.targetTemp)
    		return true;
    	end
    	
    	def modeSet(modeStr)
    	    var s = self.fa41.lastState.clone()
    	    var mode
    	    var active
    	    if modeStr == "off"
    	        mode = s.mode
    	        active = false
    	    else
    	        mode = modeStr
    	        active = true
    	    end
    		
    		self.fa41.command(active, mode, s.fan, s.targetTemp)
    		return true;
    	end
    	
	def init()
		log("Driver init")
		self.fa41 = FakeA41()
		tasmota.add_rule("MQTT#Connected", def () self.mqttConnected() end)
		mqtt.subscribe(HA_TEMP_COMMAND_TOPIC, / topic, idx, data, databytes -> self.tempSet(data) )
		mqtt.subscribe(HA_MODE_COMMAND_TOPIC, / topic, idx, data, databytes -> self.modeSet(data) )
		mqtt.subscribe(HA_FAN_COMMAND_TOPIC, / topic, idx, data, databytes -> self.fanSet(data) )
		log("Driver init done")
	end

	# send a command to the unit.
	# es: DaikinCtrl {"active":false, "mode":"COOL", "fan":"NIGHT", "temperature":20, "swingH":false, "swingV":false }
 # Deprecated
	def cmdControl(cmdx, idx, payload, j)
		
		try
			if j == nil
				raise "type_error", "request is not valid json"
			end
			var active = j['active']
			var mode = j['mode']  # "FAN", "COOL", "DRY", "HEAT"
			var fan = j['fan']    # "1", "2", "3", "4", "Auto", "Night"
			var temperature = j['temperature']
			var swingV = j['swingV']
			var swingH = j['swingH']

			self.fa41.command(active, mode, fan, temperature, swingH, swingV)

			tasmota.resp_cmnd_done()
			
			tasmota.set_timer(100, / -> tasmota.cmd('TelePeriod')) # run teleperiod to update the state to home automation
		except .. as e, v
			log("Error in Daikin cmd: "+str(e) + ' ' + str(v))
			tasmota.resp_cmnd_str("ERR: "+str(e) + ' ' + str(v))
		end
	end
end

log("Daikin setup started")
var fakeA41Driver = FakeA41Driver()
tasmota.add_driver(fakeA41Driver)

log("Daikin driver installed")


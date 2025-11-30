import { Elector } from './Elector';
import { Address, Cell, beginCell, Dictionary, ContractProvider, DictionaryValue } from '@ton/core';
import { loadConfig, getStakeConf, packElect, getElectionsConf } from './ValidatorUtils';
import { Blockchain, BlockchainContractProvider, SandboxContractProvider, TickOrTock } from '@ton/sandbox';

export class ElectorTest extends Elector {
  constructor(readonly address: Address, readonly init?: { code: Cell; data: Cell, special:{tick:boolean, tock:boolean} }) {
    super(address, init);
  }


	static emptyState(curHash: bigint = 0n) {
  	return beginCell()
  	        .storeMaybeRef(null) 
  	        .storeMaybeRef(null)
  	        .storeMaybeRef(null)
  	        .storeCoins(0)
            .storeUint(0, 32)
  	        .storeUint(0, 256)
  	       .endCell();
	}

	static electionsAnnounced(config:Cell,prev_state:Cell | null = null, now:number = Math.floor(Date.now() / 1000)) {
		const confDict = loadConfig(config);
		const elConf   = getElectionsConf(config);
		const sConf    = getStakeConf(confDict);
		const electAt  = now + elConf.begin_before;
		const electClose = electAt - elConf.end_before;
		const elect    = packElect(electAt, electClose, sConf.min_stake, 0n, null, false, false);
		const curState = prev_state !== null ? prev_state : ElectorTest.emptyState();
		const ss       = curState.beginParse();
		const oldElect = ss.loadMaybeRef();
		const oldCredits = ss.loadMaybeRef();

		return beginCell().storeMaybeRef(elect).storeMaybeRef(oldCredits).storeSlice(ss).endCell();
	}

  static createFromAddress(address: Address) {
      return new ElectorTest(address);
  }

  static createFromCode(address: Address, code: Cell) {
     const data = ElectorTest.emptyState();
     const init = {code, data, special:{tick: true, tock:true}};

     return new ElectorTest(address, init);
  }

  static createFromState(address: Address, code: Cell, config:Cell, state:'empty' | 'announced') {
    const data = state == 'empty' ? ElectorTest.emptyState() : ElectorTest.electionsAnnounced(config);
    const init = {code, data, special: {tick: true, tock:true}};

    return new ElectorTest(address, init);
  }

  async sendTickTock(provider: SandboxContractProvider, which: TickOrTock) {
    await provider.tickTock(which);
  }
  async getParticipantsDict(provider: ContractProvider) {
        const state = await provider.getState();
        if(state.state.type !== 'active') {
            throw new Error("Elector is not active!");
        }
        const participantInfo: () => DictionaryValue<void> = () => {
            return {
                serialize(src, builder) {
                    throw new Error("Serialize not implemented!")
                },
                parse(slice) {
                }
            }
        }

        const dataCell = Cell.fromBoc(state.state.data!)[0];
        return Dictionary.load(Dictionary.Keys.BigUint(256), participantInfo(), dataCell);
  }

}

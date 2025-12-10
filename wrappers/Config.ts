import { Address, Cell, Contract, ContractProvider, Dictionary} from "@ton/core";

export class Config implements Contract {
	constructor(readonly address: Address,readonly init?: { code: Cell; data: Cell}){}

	static createFromAddress(address: Address) {
		return new Config(address);
	}
    async getConfigCell(provider: ContractProvider) {
        const state = await provider.getState();
        if(state.state.type !== "active") {
            throw new Error(`Config contract is ${state.state.type}`);
        }
        if(!state.state.data) {
            throw new Error("Unable to retrieve config state data");
        }
        const dataCell = Cell.fromBoc(state.state.data)[0];
        return dataCell.refs[0];
    }
    async getConfigDict(provider: ContractProvider) {
        const configCell = await this.getConfigCell(provider);
        return Dictionary.loadDirect(Dictionary.Keys.Int(32), Dictionary.Values.Cell(), configCell);
    }
}

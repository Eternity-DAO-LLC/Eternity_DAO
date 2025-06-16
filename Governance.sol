// SPDX-License-Identifier: MIT


// @Author Cristian F. Taborda tabordacristianfernando@gmail.com
// @Dev Ethernity - DAO
// @title RetireFound release 1.0


pragma solidity ^0.8.2;

import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

// Definición básica del token de gobernanza
contract GovernanceToken is ERC20 {
    constructor() ERC20("DAOGToken o GERAS", "GER") {
        // Nombre todavia a definir 
        // No minteamos tokens al inicio, se mintean con los depósitos en la DAO
    }

    // Solo el contrato de la DAO puede mintear tokens
    function mint(address to, uint256 amount) public virtual {
        _mint(to, amount);
    }
}


contract DAOWallet is Ownable {
    using SafeMath for uint256;

    // --- Variables de Estado ---
    GovernanceToken public governanceToken;

    // Array de direcciones de los "protocolos DeFi" (placeholders)
    address[] public defiProtocols;
    uint256 public currentDeFiProtocolIndex; // Para el ciclo de transferencia

    uint256 public constant FEE_PERCENTAGE = 20; // 2% (20/1000 = 0.02)
    uint256 public constant PERCENTAGE_DENOMINATOR = 1000; // Para representar 2%
    uint256 public constant MONTH = 30 days;

    // Información del usuario para el retiro de fondos
    struct UserDepositInfo {
        uint256 totalDeposited;
        uint256 initialDepositTimestamp;
        
        uint8 ageAtFirstDeposit; // Edad al momento del primer depósito (NO en el contrato) ZK
        string gender;           // "male" o "female" (NO en el contrato) Zero-Knowledge?
        uint256 unlockTimestamp; // Timestamp a partir del cual se puede retirar
        bool hasGovernanceTokenThisMonth; // Para el requisito mensual del token
        uint256 lastDepositMonth; // Para rastrear el uso mensual
    }

    mapping(address => UserDepositInfo) public userDeposits;

    // Eventos
    event FundsDeposited(address indexed user, uint256 amount, uint256 netAmount, uint256 feeAmount);
    event FundsTransferredToDeFi(address indexed protocol, uint256 amount);
    event GovernanceTokenMinted(address indexed user, uint256 amount);
    event FundsWithdrawn(address indexed user, uint256 amount, string reason);
    event DeFiProtocolAdded(address indexed newProtocol);

    // --- Constructor ---
    constructor(address _governanceTokenAddress) Ownable(msg.sender) {
        require(_governanceTokenAddress != address(0), "Direccion del token de gobernanza invalida");
        governanceToken = GovernanceToken(_governanceTokenAddress);
        currentDeFiProtocolIndex = 0;
    }

    // --- Funciones del Owner ---

    /// @notice Permite al propietario añadir una dirección de protocolo DeFi.
    /// @param _protocol La dirección del contrato del protocolo DeFi.
    ///        _user La direccion del usuario para retirar o depositar
    ///        _amount La cantidad a retirar
    function addDeFiProtocol(address _protocol) public onlyOwner {
        require(_protocol != address(0), "Direccion de protocolo invalida");
        defiProtocols.push(_protocol);
        emit DeFiProtocolAdded(_protocol);
    }

    /// @notice Permite al propietario retirar fondos en nombre de un usuario si no se cumple el timestamp.
    ///         Esto debería ser una medida de emergencia y se debe usar con cautela.
    function ownerWithdraw(address _user, uint256 _amount) public onlyOwner {
        UserDepositInfo storage info = userDeposits[_user];
        require(info.totalDeposited >= _amount, "Cantidad a retirar excede el balance del usuario");
        require(_amount > 0, "La cantidad debe ser mayor a cero");

        info.totalDeposited = info.totalDeposited.sub(_amount);
        payable(_user).transfer(_amount); // Considerar patrones pull o reentrancy guards en un contrato real
        emit FundsWithdrawn(_user, _amount, "Retiro autorizado por el propietario");
    }

    // --- Funciones para Usuarios ---

    /// @notice Permite a los usuarios depositar fondos en la DAO.
    /// Los parametros _age y _gender deberian ir en el Front de la App al utilizar la 
    /// "Calculadora de Interes Compuesto" para determinar el Monto Mensual a Depositar o un Retiro Mensual
    function deposit(uint8 _age, string calldata _gender) public payable {
        require(msg.value > 0, "Debe depositar una cantidad mayor a cero");
        require(_age > 0 && _age < 120, "Edad invalida");
        require(keccak256(abi.encodePacked(_gender)) == keccak256(abi.encodePacked("male")) ||
                keccak256(abi.encodePacked(_gender)) == keccak256(abi.encodePacked("female")), "Genero invalido");

        uint256 feeAmount = msg.value.mul(FEE_PERCENTAGE).div(PERCENTAGE_DENOMINATOR); // 0.5%
        uint256 netAmount = msg.value.sub(feeAmount);

        // Cobrar el fee a la DAO (se queda en el contrato)
        // En un contrato real, podrías tener una función `withdrawFees` para el owner.

        // Almacenar información del usuario
        UserDepositInfo storage info = userDeposits[msg.sender];
        if (info.totalDeposited == 0) { // Primer depósito del usuario
            info.initialDepositTimestamp = block.timestamp;
            info.ageAtFirstDeposit = _age;
            info.gender = _gender;

            // Calcular unlockTimestamp
            uint256 yearsToUnlock;
            if (keccak256(abi.encodePacked(_gender)) == keccak256(abi.encodePacked("male"))) {
                require(_age <= 67, "Su edad excede la edad de retiro para hombres");
                yearsToUnlock = 67 - _age;
            } else { // female
                require(_age <= 65, "Su edad excede la edad de retiro para mujeres");
                yearsToUnlock = 65 - _age;
            }
            info.unlockTimestamp = block.timestamp.add(yearsToUnlock.mul(365 days)); // Aproximado
        }

        info.totalDeposited = info.totalDeposited.add(netAmount);

        // Emitir un token de gobernanza si es la primera vez en el mes
        uint256 currentMonth = block.timestamp / MONTH;
        if (info.lastDepositMonth != currentMonth) {
            if (!info.hasGovernanceTokenThisMonth) {
                 // Solo mintea si aún no tiene uno este mes
                governanceToken.mint(msg.sender, 1); // Mintear 1 token de gobernanza
                info.hasGovernanceTokenThisMonth = true;
                emit GovernanceTokenMinted(msg.sender, 1);
            }
            info.lastDepositMonth = currentMonth;
        }


        emit FundsDeposited(msg.sender, msg.value, netAmount, feeAmount);

        // Transferir fondos al siguiente protocolo DeFi
        _transferToDeFi(netAmount);
    }

    /// @notice Permite a los usuarios retirar sus fondos después de que se cumpla el timestamp de retiro.
    function withdraw() public {
        UserDepositInfo storage info = userDeposits[msg.sender];
        require(info.totalDeposited > 0, "No tiene fondos para retirar");
        require(block.timestamp >= info.unlockTimestamp, "Los fondos estan bloqueados hasta el timestamp de retiro");

        uint256 amountToWithdraw = info.totalDeposited;
        info.totalDeposited = 0; // Resetear el balance después del retiro

        payable(msg.sender).transfer(amountToWithdraw); // Considerar patrones pull o reentrancy guards
        emit FundsWithdrawn(msg.sender, amountToWithdraw, "Retiro por cumplimiento de timestamp");
    }

    /// @notice Permite a los usuarios actualizar su estado mensual del token de gobernanza.
    ///         Esto puede ser llamado para restablecer la elegibilidad para recibir 
    ///         un token el próximo mes, garantizando el aporte mensual. 
    function updateGovernanceTokenStatus() public {
        UserDepositInfo storage info = userDeposits[msg.sender];
        uint256 currentMonth = block.timestamp / MONTH;
        if (info.lastDepositMonth != currentMonth) {
            info.hasGovernanceTokenThisMonth = false; // Resetear para el nuevo mes
        }
    }


    // --- Funciones Internas ---

    /// @dev Transfiere una cantidad de Ether al siguiente protocolo DeFi en el ciclo.
    ///      Esta función es un placeholder. En una implementación real, aquí iría
    ///      la lógica para interactuar con los contratos de los protocolos DeFi.
    function _transferToDeFi(uint256 _amount) internal {
        require(defiProtocols.length > 0, "No hay protocolos DeFi configurados");

        address targetProtocol = defiProtocols[currentDeFiProtocolIndex];


        // Para interactuar con DeFi real, NO usaría `.transfer()`.
        // Necesitarías:
        // 1. Una interfaz específica para el protocolo 
        // 2. O si es para depositar Ether, llamar a una función `deposit` en el contrato del protocolo
        // 3. Posibilidad de poder depositar Fiat en Crypto o USD, ARS, BR, etc.
        // 4. Manejo de errores y reentrancy.
        (bool success, ) = targetProtocol.call{value: _amount}(""); // Simulación de envío de Ether

        require(success, "Fallo al transferir a protocolo DeFi");

        emit FundsTransferredToDeFi(targetProtocol, _amount);

        // Avanzar al siguiente protocolo o volver al inicio
        currentDeFiProtocolIndex = (currentDeFiProtocolIndex + 1) % defiProtocols.length;
    }

    // --- Funciones de Visibilidad ---

    /// @param _user La dirección del usuario.
    /// @return El balance total depositado por el usuario.
    function getUserTotalDeposited(address _user) public view returns (uint256) {
        return userDeposits[_user].totalDeposited;
    }

    /// @return El timestamp a partir del cual los fondos están disponibles para retiro.
    function getUserUnlockTimestamp(address _user) public view returns (uint256) {
        return userDeposits[_user].unlockTimestamp;
    }

    /// @notice Devuelve el número de protocolos DeFi configurados. (Solo por seguridad, puede no ser necesario)
    function getDeFiProtocolsCount() public view returns (uint256) {
        return defiProtocols.length;
    }
}